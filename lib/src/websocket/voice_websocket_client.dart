import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'voice_websocket_config.dart';

enum VoiceWebSocketStatus {
  unconfigured,
  disconnected,
  connecting,
  ready,
  error,
}

typedef VoiceWebSocketConnector =
    Future<WebSocket> Function(Uri uri, Map<String, Object> headers);

typedef VoiceWebSocketInboundMessage = Future<void> Function(String message);

final class AgentTranscriptRoute {
  const AgentTranscriptRoute({required this.agent, required this.message});

  final String agent;
  final String message;
}

final class VoiceWebSocketClient extends ChangeNotifier {
  VoiceWebSocketClient({
    VoiceWebSocketConfigStore? configStore,
    VoiceWebSocketConnector connector = _connect,
    VoiceWebSocketInboundMessage? onInboundMessage,
    Duration readyTimeout = const Duration(seconds: 10),
    Duration acknowledgementTimeout = const Duration(seconds: 10),
    List<Duration> reconnectDelays = const <Duration>[
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 4),
      Duration(seconds: 8),
      Duration(seconds: 15),
    ],
  }) : _configStore = configStore ?? VoiceWebSocketConfigStore(),
       _connector = connector,
       _onInboundMessage = onInboundMessage,
       _readyTimeout = readyTimeout,
       _acknowledgementTimeout = acknowledgementTimeout,
       _reconnectDelays = reconnectDelays;

  final VoiceWebSocketConfigStore _configStore;
  final VoiceWebSocketConnector _connector;
  final VoiceWebSocketInboundMessage? _onInboundMessage;
  final Duration _readyTimeout;
  final Duration _acknowledgementTimeout;
  final List<Duration> _reconnectDelays;
  final Random _random = Random.secure();
  final Map<String, _PendingAcknowledgement> _pending =
      <String, _PendingAcknowledgement>{};

  WebSocket? _socket;
  StreamSubscription<dynamic>? _subscription;
  Timer? _readyTimer;
  Timer? _reconnectTimer;
  Completer<void>? _readyCompleter;
  bool _initialized = false;
  bool _disposed = false;
  bool _manualDisconnect = false;
  bool _everReady = false;
  int _generation = 0;
  int _reconnectAttempt = 0;
  int? _lastEventId;
  Future<void> _inboundTail = Future<void>.value();

  VoiceWebSocketStatus status = VoiceWebSocketStatus.unconfigured;
  String statusText = 'Not configured';
  List<String> serverAgents = const <String>[];
  List<String> agentControls = const <String>[];
  List<String> sessionControls = const <String>[];

  VoiceWebSocketConfig get config => _configStore.config;
  String? get validationError => _configStore.validationError;

  bool get isReady => status == VoiceWebSocketStatus.ready;

  Future<void> initialize() async {
    if (_initialized || _disposed) {
      return;
    }
    _initialized = true;
    _configStore.addListener(_configChanged);
    await _configStore.initialize();
    if (!config.isConfigured) {
      _setStatus(VoiceWebSocketStatus.unconfigured, 'Not configured');
      return;
    }
    _setStatus(VoiceWebSocketStatus.disconnected, 'Saved · disconnected');
    unawaited(_connectIgnoringErrors());
  }

  Future<void> saveConfig(VoiceWebSocketConfig value) async {
    _requireInitialized();
    await _configStore.save(value);
    await _closeSocket(reconnect: false);
    _manualDisconnect = false;
    _reconnectAttempt = 0;
    _everReady = false;
    _lastEventId = null;
    serverAgents = const <String>[];
    agentControls = const <String>[];
    sessionControls = const <String>[];
    _setStatus(VoiceWebSocketStatus.disconnected, 'Saved · disconnected');
    unawaited(_connectIgnoringErrors());
  }

  Future<void> connect() async {
    _requireInitialized();
    if (!config.isConfigured) {
      throw StateError('Save a valid connection before connecting.');
    }
    if (_disposed) {
      throw StateError('The WebSocket client is closed.');
    }
    if (isReady) {
      return;
    }
    final waiting = _readyCompleter;
    if (status == VoiceWebSocketStatus.connecting &&
        waiting != null &&
        !waiting.isCompleted) {
      return waiting.future;
    }

    _manualDisconnect = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _generation++;
    final generation = _generation;
    final ready = Completer<void>();
    _readyCompleter = ready;
    _setStatus(VoiceWebSocketStatus.connecting, 'Connecting…');

    try {
      final socket = await _connector(config.uri, config.upgradeHeaders);
      if (_disposed || generation != _generation) {
        await socket.close();
        if (!ready.isCompleted) {
          ready.completeError(
            StateError('The WebSocket connection was replaced.'),
          );
        }
        return ready.future;
      }
      _socket = socket;
      socket.pingInterval = const Duration(seconds: 20);
      _subscription = socket.listen(
        (data) {
          _inboundTail = _inboundTail
              .then((_) => _handleSocketData(data, generation))
              .catchError((_) {
                // Delivery failures publish a generic status and reconnect
                // without exposing private message content.
              });
        },
        onDone: () => _handleSocketClosed(generation),
        onError: (_) => _handleSocketClosed(generation),
        cancelOnError: true,
      );
      _readyTimer = Timer(_readyTimeout, () {
        if (generation != _generation || isReady) {
          return;
        }
        _setStatus(VoiceWebSocketStatus.error, 'Server did not become ready');
        if (!ready.isCompleted) {
          ready.completeError(
            TimeoutException(
              'The WebSocket server did not send connection.ready.',
            ),
          );
        }
        unawaited(_closeSocket(reconnect: true));
      });
    } on Object {
      if (generation == _generation && !_disposed) {
        _setStatus(
          VoiceWebSocketStatus.error,
          'Could not connect · check address, port, and server',
        );
        _scheduleReconnect();
      }
      if (!ready.isCompleted) {
        ready.completeError(
          StateError('The WebSocket server could not be reached.'),
        );
      }
    }
    return ready.future;
  }

  Future<void> disconnect() async {
    _manualDisconnect = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await _closeSocket(reconnect: false);
    if (!_disposed) {
      _setStatus(
        config.isConfigured
            ? VoiceWebSocketStatus.disconnected
            : VoiceWebSocketStatus.unconfigured,
        config.isConfigured ? 'Saved · disconnected' : 'Not configured',
      );
    }
  }

  AgentTranscriptRoute? routeForTranscript(String transcript) {
    final text = transcript.trim();
    if (text.isEmpty) {
      return null;
    }
    _AgentMatch? selected;
    for (final agent in config.agentNames) {
      final match = RegExp(
        '(^|[^A-Za-z0-9_])(${RegExp.escape(agent)})(?=\$|[^A-Za-z0-9_])',
        caseSensitive: false,
      ).firstMatch(text);
      if (match == null) {
        continue;
      }
      final nameStart = match.start + (match.group(1)?.length ?? 0);
      final candidate = _AgentMatch(
        agent: agent,
        start: nameStart,
        end: match.end,
      );
      if (selected == null ||
          candidate.start < selected.start ||
          candidate.start == selected.start &&
              candidate.agent.length > selected.agent.length) {
        selected = candidate;
      }
    }
    if (selected == null) {
      return null;
    }

    var message = text;
    if (selected.start == 0) {
      message = text
          .substring(selected.end)
          .replaceFirst(RegExp(r'^[\s,:;.!?\-–—]+'), '')
          .trim();
      if (message.isEmpty) {
        message = text;
      }
    }
    return AgentTranscriptRoute(agent: selected.agent, message: message);
  }

  Future<bool> sendTranscript(String transcript) async {
    final route = routeForTranscript(transcript);
    if (route == null) {
      return false;
    }
    return sendAgentMessage(agent: route.agent, message: route.message);
  }

  Future<bool> sendAgentMessage({
    required String agent,
    required String message,
  }) async {
    final canonicalAgent = config.agentNames.firstWhere(
      (name) => name.toLowerCase() == agent.trim().toLowerCase(),
      orElse: () => '',
    );
    final trimmedMessage = message.trim();
    if (canonicalAgent.isEmpty || trimmedMessage.isEmpty) {
      return false;
    }
    try {
      await connect();
    } on Object {
      return false;
    }
    final socket = _socket;
    if (socket == null || !isReady) {
      return false;
    }

    if (config.useLegacyMessageShape) {
      try {
        socket.add(
          jsonEncode(<String, Object>{
            'agent': canonicalAgent,
            'message': trimmedMessage,
          }),
        );
        return true;
      } on Object {
        return false;
      }
    }

    final requestId = _newRequestId();
    for (var attempt = 0; attempt < 2; attempt++) {
      if (attempt > 0 ||
          _socket == null ||
          _socket!.readyState != WebSocket.open ||
          !isReady) {
        if (attempt > 0 || _socket != null) {
          await _closeSocket(reconnect: false);
        }
        try {
          await connect();
        } on Object {
          return false;
        }
      }

      final activeSocket = _socket;
      if (activeSocket == null ||
          activeSocket.readyState != WebSocket.open ||
          !isReady) {
        continue;
      }
      final completer = Completer<_AcknowledgementOutcome>();
      final timer = Timer(_acknowledgementTimeout, () {
        final pending = _pending.remove(requestId);
        if (pending != null && !pending.completer.isCompleted) {
          pending.completer.complete(_AcknowledgementOutcome.timedOut);
        }
      });
      _pending[requestId] = _PendingAcknowledgement(
        completer: completer,
        timer: timer,
      );
      try {
        activeSocket.add(
          jsonEncode(<String, Object>{
            'type': 'message.send',
            'request_id': requestId,
            'agent': canonicalAgent,
            'message': trimmedMessage,
          }),
        );
      } on Object {
        final pending = _pending.remove(requestId);
        pending?.timer.cancel();
        if (!(pending?.completer.isCompleted ?? true)) {
          pending!.completer.complete(_AcknowledgementOutcome.connectionLost);
        }
      }
      final outcome = await completer.future;
      if (outcome == _AcknowledgementOutcome.accepted) {
        return true;
      }
      if (outcome == _AcknowledgementOutcome.rejected) {
        return false;
      }
    }
    return false;
  }

  Future<void> _handleSocketData(Object? data, int generation) async {
    if (_disposed || generation != _generation || data is! String) {
      return;
    }
    Object? decoded;
    try {
      decoded = jsonDecode(data);
    } on FormatException {
      final message = data.trim();
      if (message.isNotEmpty) {
        await _deliverInbound(message, generation);
      }
      return;
    }
    if (decoded is! Map<String, dynamic>) {
      return;
    }
    final type = decoded['type'];
    if (type == 'connection.ready') {
      _handleReady(decoded, generation);
      return;
    }
    if (type == 'message.accepted') {
      _handleAcknowledgement(decoded);
      return;
    }
    if (type == 'message.error') {
      _handleRejection(decoded);
      return;
    }
    if (type is String &&
        (type.startsWith('connection.') || type == 'pong' || type == 'ping')) {
      return;
    }
    final message = _extractMessage(decoded);
    if (message != null) {
      final delivered = await _deliverInbound(message, generation);
      if (!delivered || generation != _generation) {
        return;
      }
    }
    _captureAndAcknowledgeEvent(decoded);
  }

  void _handleReady(Map<String, dynamic> payload, int generation) {
    if (generation != _generation || payload['version'] != 1) {
      return;
    }
    _readyTimer?.cancel();
    _readyTimer = null;
    serverAgents = _stringList(payload['agents']);
    agentControls = _stringList(payload['agent_controls']);
    sessionControls = _stringList(payload['session_controls']);
    final socket = _socket;
    if (_everReady && _lastEventId != null && socket != null) {
      socket.add(
        jsonEncode(<String, Object>{
          'type': 'connection.resume',
          'resume_after_event_id': _lastEventId!,
        }),
      );
    }
    _everReady = true;
    _reconnectAttempt = 0;
    _setStatus(
      VoiceWebSocketStatus.ready,
      serverAgents.isEmpty
          ? 'Connected · ready'
          : 'Connected · ${serverAgents.length} server agents',
    );
    final ready = _readyCompleter;
    if (ready != null && !ready.isCompleted) {
      ready.complete();
    }
  }

  void _handleAcknowledgement(Map<String, dynamic> payload) {
    final requestId = payload['request_id'];
    if (requestId is! String) {
      return;
    }
    final pending = _pending.remove(requestId);
    if (pending == null) {
      return;
    }
    pending.timer.cancel();
    final result = payload['result'];
    final resultSent = result is Map<String, dynamic> ? result['sent'] : null;
    final accepted = payload['ok'] == true && resultSent != false;
    if (!pending.completer.isCompleted) {
      pending.completer.complete(
        accepted
            ? _AcknowledgementOutcome.accepted
            : _AcknowledgementOutcome.rejected,
      );
    }
  }

  void _handleRejection(Map<String, dynamic> payload) {
    final requestId = payload['request_id'];
    if (requestId is! String) {
      return;
    }
    final pending = _pending.remove(requestId);
    if (pending == null) {
      return;
    }
    pending.timer.cancel();
    if (!pending.completer.isCompleted) {
      pending.completer.complete(_AcknowledgementOutcome.rejected);
    }
  }

  Future<bool> _deliverInbound(String message, int generation) async {
    final handler = _onInboundMessage;
    if (handler == null) {
      return true;
    }
    try {
      await handler(message);
      return true;
    } on Object {
      if (!_disposed && generation == _generation) {
        _setStatus(
          VoiceWebSocketStatus.error,
          'Could not save server message · retrying',
        );
        unawaited(_closeSocket(reconnect: true));
      }
      return false;
    }
  }

  void _captureAndAcknowledgeEvent(Map<String, dynamic> payload) {
    final eventId = payload['event_id'];
    final parsed = switch (eventId) {
      int value => value,
      String value => int.tryParse(value),
      _ => null,
    };
    if (parsed != null && parsed >= 0) {
      _lastEventId = parsed;
      final socket = _socket;
      if (socket != null && socket.readyState == WebSocket.open) {
        try {
          socket.add(
            jsonEncode(<String, Object>{
              'type': 'event.ack',
              'event_id': parsed,
            }),
          );
        } on Object {
          // The durable cursor is retained for connection.resume if this ACK
          // was lost with the socket.
        }
      }
    }
  }

  String? _extractMessage(Map<String, dynamic> payload) {
    String? message;
    for (final key in const <String>[
      'summary',
      'completion_message',
      'message',
      'text',
      'content',
      'detail',
    ]) {
      final value = payload[key];
      if (value is String && value.trim().isNotEmpty) {
        message = value.trim();
        break;
      }
    }
    if (message == null) {
      final detailLines = payload['detail_lines'];
      if (detailLines is List<dynamic>) {
        final lines = detailLines
            .whereType<String>()
            .map((line) => line.trim())
            .where((line) => line.isNotEmpty)
            .toList(growable: false);
        if (lines.isNotEmpty) {
          message = lines.join('\n');
        }
      }
    }
    for (final key in const <String>['payload', 'result', 'data']) {
      if (message != null) {
        break;
      }
      final nested = payload[key];
      if (nested is Map<String, dynamic>) {
        message = _extractMessage(nested);
      }
    }
    if (message == null) {
      return null;
    }
    final agent = payload['agent'];
    if (agent is String &&
        agent.trim().isNotEmpty &&
        !message.toLowerCase().startsWith(agent.trim().toLowerCase())) {
      return '${agent.trim()}: $message';
    }
    return message;
  }

  void _handleSocketClosed(int generation) {
    if (_disposed || generation != _generation) {
      return;
    }
    _readyTimer?.cancel();
    _readyTimer = null;
    _socket = null;
    _subscription = null;
    _completePending(_AcknowledgementOutcome.connectionLost);
    final ready = _readyCompleter;
    if (ready != null && !ready.isCompleted) {
      ready.completeError(StateError('The WebSocket connection closed.'));
    }
    if (_manualDisconnect) {
      return;
    }
    _setStatus(VoiceWebSocketStatus.disconnected, 'Connection lost · retrying');
    _scheduleReconnect();
  }

  Future<void> _closeSocket({required bool reconnect}) async {
    _generation++;
    _readyTimer?.cancel();
    _readyTimer = null;
    final subscription = _subscription;
    _subscription = null;
    await subscription?.cancel();
    final socket = _socket;
    _socket = null;
    await socket?.close();
    _completePending(_AcknowledgementOutcome.connectionLost);
    final ready = _readyCompleter;
    if (ready != null && !ready.isCompleted) {
      ready.completeError(StateError('The WebSocket connection closed.'));
    }
    if (reconnect && !_manualDisconnect) {
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    if (_disposed ||
        _manualDisconnect ||
        !config.isConfigured ||
        _reconnectTimer != null ||
        _reconnectDelays.isEmpty) {
      return;
    }
    final index = _reconnectAttempt.clamp(0, _reconnectDelays.length - 1);
    final delay = _reconnectDelays[index];
    _reconnectAttempt++;
    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      unawaited(_connectIgnoringErrors());
    });
  }

  Future<void> _connectIgnoringErrors() async {
    try {
      await connect();
    } on Object {
      // Status and retry state are published without exposing endpoint or
      // authentication values through logs.
    }
  }

  void _completePending(_AcknowledgementOutcome outcome) {
    for (final pending in _pending.values) {
      pending.timer.cancel();
      if (!pending.completer.isCompleted) {
        pending.completer.complete(outcome);
      }
    }
    _pending.clear();
  }

  void _configChanged() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  void _setStatus(VoiceWebSocketStatus next, String text) {
    final changed = status != next || statusText != text;
    status = next;
    statusText = text;
    if (changed && !_disposed) {
      notifyListeners();
    }
  }

  String _newRequestId() {
    final random = List<int>.generate(12, (_) => _random.nextInt(256));
    final suffix = random
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${DateTime.now().microsecondsSinceEpoch}-$suffix';
  }

  void _requireInitialized() {
    if (!_initialized) {
      throw StateError('Voice WebSocket configuration is not initialized.');
    }
  }

  Future<void> close() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _manualDisconnect = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _configStore.removeListener(_configChanged);
    await _closeSocket(reconnect: false);
    _configStore.dispose();
  }

  @override
  void dispose() {
    unawaited(close());
    super.dispose();
  }

  static Future<WebSocket> _connect(Uri uri, Map<String, Object> headers) =>
      WebSocket.connect(uri.toString(), headers: headers);

  static List<String> _stringList(Object? value) {
    if (value is! List<dynamic>) {
      return const <String>[];
    }
    return List<String>.unmodifiable(
      value
          .whereType<String>()
          .map((item) => item.trim())
          .where((item) => item.isNotEmpty),
    );
  }
}

final class _AgentMatch {
  const _AgentMatch({
    required this.agent,
    required this.start,
    required this.end,
  });

  final String agent;
  final int start;
  final int end;
}

final class _PendingAcknowledgement {
  const _PendingAcknowledgement({required this.completer, required this.timer});

  final Completer<_AcknowledgementOutcome> completer;
  final Timer timer;
}

enum _AcknowledgementOutcome { accepted, rejected, connectionLost, timedOut }
