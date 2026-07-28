import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../websocket/voice_websocket_client.dart';
import '../websocket/voice_websocket_config.dart';
import 'workbench_theme.dart';

final class VoiceWebSocketSettings extends StatefulWidget {
  const VoiceWebSocketSettings({
    required this.config,
    required this.status,
    required this.statusText,
    required this.busy,
    required this.onSave,
    required this.onConnect,
    required this.onDisconnect,
    this.validationError,
    super.key,
  });

  final VoiceWebSocketConfig config;
  final VoiceWebSocketStatus status;
  final String statusText;
  final String? validationError;
  final bool busy;
  final Future<void> Function(VoiceWebSocketConfig config) onSave;
  final Future<void> Function() onConnect;
  final Future<void> Function() onDisconnect;

  @override
  State<VoiceWebSocketSettings> createState() => _VoiceWebSocketSettingsState();
}

final class _VoiceWebSocketSettingsState extends State<VoiceWebSocketSettings> {
  final _formKey = GlobalKey<FormState>();
  final _hostFocus = FocusNode();
  final _portFocus = FocusNode();
  final _secretFocus = FocusNode();
  final _agentsFocus = FocusNode();
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _secret;
  late final TextEditingController _agents;
  late VoiceWebSocketAuthHeader _authHeader;
  late bool _legacyShape;
  bool _obscureSecret = true;
  bool _saving = false;

  bool get _isEditing =>
      _hostFocus.hasFocus ||
      _portFocus.hasFocus ||
      _secretFocus.hasFocus ||
      _agentsFocus.hasFocus;

  @override
  void initState() {
    super.initState();
    _host = TextEditingController(text: widget.config.host);
    _port = TextEditingController(text: '${widget.config.port}');
    _secret = TextEditingController(text: widget.config.secret);
    _agents = TextEditingController(text: widget.config.agentNames.join('\n'));
    _authHeader = widget.config.authHeader;
    _legacyShape = widget.config.useLegacyMessageShape;
  }

  @override
  void didUpdateWidget(VoiceWebSocketSettings oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_isEditing && widget.config != oldWidget.config) {
      _host.text = widget.config.host;
      _port.text = '${widget.config.port}';
      _secret.text = widget.config.secret;
      _agents.text = widget.config.agentNames.join('\n');
      _authHeader = widget.config.authHeader;
      _legacyShape = widget.config.useLegacyMessageShape;
    }
  }

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    _secret.dispose();
    _agents.dispose();
    _hostFocus.dispose();
    _portFocus.dispose();
    _secretFocus.dispose();
    _agentsFocus.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving || !(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    final port = int.parse(_port.text);
    final agentNames = _agents.text.split(RegExp(r'[,\n]'));
    final config = VoiceWebSocketConfig.validate(
      host: _host.text,
      port: port,
      secret: _secret.text,
      authHeader: _authHeader,
      agentNames: agentNames,
      useLegacyMessageShape: _legacyShape,
    );
    setState(() => _saving = true);
    try {
      await widget.onSave(config);
      if (mounted) {
        FocusScope.of(context).unfocus();
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final disabled = widget.busy || _saving;
    final connected = widget.status == VoiceWebSocketStatus.ready;
    final connectionActive =
        connected || widget.status == VoiceWebSocketStatus.connecting;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('Voice WebSocket', style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(
          'Route a finalized transcript when it names a saved agent. Server '
          'messages and transcript send status appear on G2.',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 8),
        Row(
          children: <Widget>[
            Icon(
              Icons.circle,
              size: 8,
              color: connected ? connectedStatusColor : inactiveStatusColor,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'WebSocket ${widget.statusText}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Form(
          key: _formKey,
          child: Column(
            children: <Widget>[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Expanded(
                    child: TextFormField(
                      key: const Key('voice-websocket-ip'),
                      controller: _host,
                      focusNode: _hostFocus,
                      enabled: !disabled,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      inputFormatters: <TextInputFormatter>[
                        FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                        LengthLimitingTextInputFormatter(15),
                      ],
                      decoration: const InputDecoration(
                        labelText: 'IP address',
                        hintText: '127.0.0.1',
                      ),
                      validator: (value) {
                        try {
                          VoiceWebSocketConfig.validateIpv4(value ?? '');
                          return null;
                        } on FormatException catch (error) {
                          return error.message;
                        }
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 104,
                    child: TextFormField(
                      key: const Key('voice-websocket-port'),
                      controller: _port,
                      focusNode: _portFocus,
                      enabled: !disabled,
                      keyboardType: TextInputType.number,
                      inputFormatters: <TextInputFormatter>[
                        FilteringTextInputFormatter.digitsOnly,
                        LengthLimitingTextInputFormatter(5),
                      ],
                      decoration: const InputDecoration(
                        labelText: 'Port',
                        hintText: '8787',
                      ),
                      validator: (value) {
                        final port = int.tryParse(value ?? '');
                        if (port == null || port < 1 || port > 65535) {
                          return 'Use 1–65535.';
                        }
                        return null;
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TextFormField(
                key: const Key('voice-websocket-secret'),
                controller: _secret,
                focusNode: _secretFocus,
                enabled: !disabled,
                obscureText: _obscureSecret,
                autocorrect: false,
                enableSuggestions: false,
                maxLength: VoiceWebSocketConfig.maximumSecretCharacters,
                decoration: InputDecoration(
                  labelText: 'Secret',
                  helperText: 'Stored only in app-private storage.',
                  suffixIcon: IconButton(
                    tooltip: _obscureSecret ? 'Show secret' : 'Hide secret',
                    onPressed: disabled
                        ? null
                        : () =>
                              setState(() => _obscureSecret = !_obscureSecret),
                    icon: Icon(
                      _obscureSecret
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                    ),
                  ),
                ),
                validator: (value) {
                  try {
                    VoiceWebSocketConfig.validateSecret(value ?? '');
                    return null;
                  } on FormatException catch (error) {
                    return error.message;
                  }
                },
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<VoiceWebSocketAuthHeader>(
                key: ValueKey<VoiceWebSocketAuthHeader>(_authHeader),
                initialValue: _authHeader,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Upgrade authentication',
                ),
                items: const <DropdownMenuItem<VoiceWebSocketAuthHeader>>[
                  DropdownMenuItem<VoiceWebSocketAuthHeader>(
                    value: VoiceWebSocketAuthHeader.authorizationBearer,
                    child: Text('Authorization: Bearer'),
                  ),
                  DropdownMenuItem<VoiceWebSocketAuthHeader>(
                    value: VoiceWebSocketAuthHeader.voiceApiToken,
                    child: Text('X-Voice-Api-Token'),
                  ),
                ],
                onChanged: disabled
                    ? null
                    : (value) {
                        if (value != null) {
                          setState(() => _authHeader = value);
                        }
                      },
              ),
              const SizedBox(height: 8),
              TextFormField(
                key: const Key('voice-websocket-agents'),
                controller: _agents,
                focusNode: _agentsFocus,
                enabled: !disabled,
                minLines: 2,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: 'Agent names',
                  hintText: 'Agent One\nAgent Two',
                  helperText:
                      'Add one name per line, or separate names by commas.',
                  alignLabelWithHint: true,
                ),
                validator: (value) {
                  try {
                    VoiceWebSocketConfig.validateAgentNames(
                      (value ?? '').split(RegExp(r'[,\n]')),
                    );
                    return null;
                  } on FormatException catch (error) {
                    return error.message;
                  }
                },
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Use legacy message shape'),
                subtitle: const Text(
                  'Send only agent and message fields, without acknowledgement.',
                ),
                value: _legacyShape,
                onChanged: disabled
                    ? null
                    : (value) => setState(() => _legacyShape = value),
              ),
            ],
          ),
        ),
        if (widget.validationError != null) ...<Widget>[
          const SizedBox(height: 4),
          Text(
            'Config validation: ${widget.validationError}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ],
        const SizedBox(height: 8),
        Text(
          'Connects to ws://IP:port/ws. On Android, 127.0.0.1 is the phone. '
          'Plain ws:// is unencrypted; use only a trusted local connection.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            FilledButton(
              onPressed: disabled ? null : _save,
              child: Text(_saving ? 'Saving…' : 'Save connection'),
            ),
            OutlinedButton(
              onPressed: disabled || !widget.config.isConfigured
                  ? null
                  : connectionActive
                  ? widget.onDisconnect
                  : widget.onConnect,
              child: Text(
                connectionActive ? 'Disconnect server' : 'Connect server',
              ),
            ),
          ],
        ),
      ],
    );
  }
}
