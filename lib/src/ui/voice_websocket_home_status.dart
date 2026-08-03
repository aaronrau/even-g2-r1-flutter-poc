import 'package:flutter/material.dart';

import '../websocket/voice_websocket_client.dart';
import 'workbench_theme.dart';

final class VoiceWebSocketHomeStatus extends StatelessWidget {
  const VoiceWebSocketHomeStatus({
    required this.host,
    required this.port,
    required this.status,
    super.key,
  });

  final String host;
  final int port;
  final VoiceWebSocketStatus status;

  @override
  Widget build(BuildContext context) {
    final endpoint = host.trim().isEmpty
        ? 'No address'
        : '${host.trim()}:$port';
    final label = switch (status) {
      VoiceWebSocketStatus.ready => 'Connected',
      VoiceWebSocketStatus.connecting => 'Connecting',
      VoiceWebSocketStatus.disconnected => 'Disconnected',
      VoiceWebSocketStatus.error => 'Error',
      VoiceWebSocketStatus.unconfigured => 'Not configured',
    };
    final connected = status == VoiceWebSocketStatus.ready;
    return Semantics(
      label: 'Agent connection $endpoint, $label',
      container: true,
      child: SizedBox(
        width: 154,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: <Widget>[
            Icon(
              Icons.circle,
              key: const ValueKey<String>('voice-websocket-status-dot'),
              size: 8,
              color: connected ? connectedStatusColor : inactiveStatusColor,
            ),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                connected ? endpoint : '$endpoint · $label',
                key: const ValueKey<String>('voice-websocket-status-text'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
