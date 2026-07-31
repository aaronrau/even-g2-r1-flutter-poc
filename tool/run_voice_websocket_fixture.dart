import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> arguments) async {
  final options = _FixtureOptions.parse(arguments);
  final server = await HttpServer.bind(options.host, options.port);
  stdout.writeln(
    'fixture_ready host=${server.address.address} port=${server.port}',
  );
  var connectionCount = 0;
  var eventId = 0;
  var busyResponsesRemaining = options.busyResponses;
  final acceptedByRequestId = <String, Map<String, Object>>{};

  Future<void> stop(ProcessSignal signal) async {
    stdout.writeln('fixture_stopping signal=${signal.name}');
    await server.close(force: true);
    exit(0);
  }

  ProcessSignal.sigint.watch().listen(stop);
  ProcessSignal.sigterm.watch().listen(stop);

  await for (final request in server) {
    final bearer = request.headers.value(HttpHeaders.authorizationHeader);
    final token = request.headers.value('X-Voice-Api-Token');
    final authenticated =
        bearer == 'Bearer ${options.secret}' || token == options.secret;
    if (request.uri.path != '/ws' || !authenticated) {
      request.response.statusCode = HttpStatus.unauthorized;
      await request.response.close();
      stdout.writeln('upgrade_rejected');
      continue;
    }

    final socket = await WebSocketTransformer.upgrade(request);
    connectionCount++;
    final connectionNumber = connectionCount;
    stdout.writeln('connection_ready number=$connectionNumber');
    socket.add(
      jsonEncode(<String, Object>{
        'type': 'connection.ready',
        'version': 1,
        'server_session_id': 'fixture-session-$connectionNumber',
        'agents': <String>['Work Bench', 'Agent One', 'Agent Two'],
        'agent_controls': <String>['Work Bench clear terminal'],
        'session_controls': <String>['Session terminate'],
        'websocket_path': '/ws',
      }),
    );

    socket.listen(
      (data) {
        if (data is! String) {
          return;
        }
        Object? decoded;
        try {
          decoded = jsonDecode(data);
        } on FormatException {
          stdout.writeln('message_rejected reason=invalid_json');
          return;
        }
        if (decoded is! Map<String, dynamic>) {
          stdout.writeln('message_rejected reason=invalid_shape');
          return;
        }
        if (decoded['type'] == 'connection.resume') {
          stdout.writeln('resume_received');
          return;
        }
        if (decoded['type'] == 'event.ack') {
          stdout.writeln('event_ack_received');
          return;
        }

        final agent = decoded['agent'];
        final summaryRequest =
            decoded['type'] == 'summary.request' ||
            decoded['type'] == 'local' &&
                decoded['message'] == 'progress_summary';
        if (summaryRequest) {
          final requestId = decoded['request_id'];
          if (agent is! String ||
              decoded['type'] == 'summary.request' &&
                  (requestId is! String || requestId.isEmpty)) {
            stdout.writeln('summary_rejected reason=invalid_fields');
            return;
          }
          socket.add(
            jsonEncode(<String, Object?>{
              'type': 'summary.result',
              'request_id': requestId,
              'ok': true,
              'result': <String, Object>{
                'agent': agent,
                'summary': 'Synthetic progress summary from fixture.',
                'detail': 'Synthetic fixture detail.',
                'detail_lines': <String>['Synthetic fixture detail.'],
                'source': 'tmux_capture',
              },
            }),
          );
          stdout.writeln(
            'summary_requested shape='
            '${decoded['type'] == 'summary.request' ? 'modern' : 'legacy'}',
          );
          return;
        }

        final modern = decoded['type'] == 'message.send';
        final message = decoded['message'];
        if (agent is! String || message is! String || message.trim().isEmpty) {
          stdout.writeln('message_rejected reason=invalid_fields');
          return;
        }
        String? requestId;
        if (modern) {
          final decodedRequestId = decoded['request_id'];
          if (decodedRequestId is! String || decodedRequestId.isEmpty) {
            stdout.writeln('message_rejected reason=missing_request_id');
            return;
          }
          requestId = decodedRequestId;
          final previous = acceptedByRequestId[requestId];
          if (previous != null) {
            socket.add(jsonEncode(previous));
            stdout.writeln('message_duplicate request_id=reused');
            return;
          }
          if (busyResponsesRemaining > 0) {
            busyResponsesRemaining--;
            socket.add(
              jsonEncode(<String, Object>{
                'type': 'message.error',
                'version': 1,
                'request_id': requestId,
                'ok': false,
                'error': <String, Object>{
                  'code': 'agent_busy',
                  'status': 'busy',
                },
              }),
            );
            stdout.writeln('message_busy remaining=$busyResponsesRemaining');
            return;
          }
          final response = <String, Object>{
            'type': 'message.accepted',
            'version': 1,
            'request_id': requestId,
            'ok': true,
            'result': <String, Object>{
              'ok': true,
              'agent': agent,
              'message': message,
              'focused': true,
              'sent': true,
            },
          };
          acceptedByRequestId[requestId] = response;
          socket.add(jsonEncode(response));
        }
        if (!options.deferProgress) {
          eventId++;
          final event = <String, Object>{
            'type': 'message.progress',
            'event_id': eventId,
            'agent': agent,
            'payload': <String, Object>{
              'agent': agent,
              'summary': 'Fixture received the agent message.',
              'phase': 'in_progress',
              'is_final': false,
            },
          };
          if (requestId != null) {
            event['request_id'] = requestId;
          }
          socket.add(jsonEncode(event));
        }
        stdout.writeln(
          'message_received shape=${modern ? 'modern' : 'legacy'} '
          'characters=${message.length}',
        );
      },
      onDone: () =>
          stdout.writeln('connection_closed number=$connectionNumber'),
      onError: (_) =>
          stdout.writeln('connection_error number=$connectionNumber'),
      cancelOnError: true,
    );
  }
}

final class _FixtureOptions {
  const _FixtureOptions({
    required this.host,
    required this.port,
    required this.secret,
    required this.busyResponses,
    required this.deferProgress,
  });

  final InternetAddress host;
  final int port;
  final String secret;
  final int busyResponses;
  final bool deferProgress;

  static _FixtureOptions parse(List<String> arguments) {
    var host = InternetAddress.loopbackIPv4;
    var port = 8787;
    var busyResponses = 0;
    var deferProgress = false;
    String? secret;
    for (var index = 0; index < arguments.length; index++) {
      switch (arguments[index]) {
        case '--host':
          if (index + 1 >= arguments.length) {
            _usageError('Missing value for --host.');
          }
          final parsed = InternetAddress.tryParse(arguments[++index]);
          if (parsed == null || parsed.type != InternetAddressType.IPv4) {
            _usageError('--host must be a numeric IPv4 address.');
          }
          host = parsed;
        case '--port':
          if (index + 1 >= arguments.length) {
            _usageError('Missing value for --port.');
          }
          port = int.tryParse(arguments[++index]) ?? 0;
        case '--secret':
          if (index + 1 >= arguments.length) {
            _usageError('Missing value for --secret.');
          }
          secret = arguments[++index];
        case '--busy-responses':
          if (index + 1 >= arguments.length) {
            _usageError('Missing value for --busy-responses.');
          }
          busyResponses = int.tryParse(arguments[++index]) ?? -1;
        case '--defer-progress':
          deferProgress = true;
        default:
          _usageError('Unknown argument: ${arguments[index]}');
      }
    }
    if (port < 1 || port > 65535) {
      _usageError('Port must be between 1 and 65535.');
    }
    if (secret == null || secret.trim().isEmpty) {
      _usageError('--secret is required.');
    }
    if (secret.contains('\r') || secret.contains('\n')) {
      _usageError('Secret must fit on one line.');
    }
    if (busyResponses < 0 || busyResponses > 100) {
      _usageError('--busy-responses must be between 0 and 100.');
    }
    return _FixtureOptions(
      host: host,
      port: port,
      secret: secret,
      busyResponses: busyResponses,
      deferProgress: deferProgress,
    );
  }

  static Never _usageError(String message) {
    stderr.writeln(message);
    stderr.writeln(
      'Usage: dart run tool/run_voice_websocket_fixture.dart '
      '--secret <local-secret> [--host 127.0.0.1] [--port 8787] '
      '[--busy-responses 1] [--defer-progress]',
    );
    exit(64);
  }
}
