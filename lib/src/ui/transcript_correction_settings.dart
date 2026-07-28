import 'package:flutter/material.dart';

import '../audio/transcript_correction_config.dart';

final class TranscriptCorrectionSettings extends StatefulWidget {
  const TranscriptCorrectionSettings({
    required this.config,
    required this.runtimeState,
    required this.pendingCount,
    required this.completedCount,
    required this.busy,
    required this.onEnabledChanged,
    required this.onSaveInstructions,
    required this.onResetInstructions,
    this.provider,
    this.validationError,
    super.key,
  });

  final TranscriptCorrectionConfig config;
  final String runtimeState;
  final String? provider;
  final String? validationError;
  final int pendingCount;
  final int completedCount;
  final bool busy;
  final Future<void> Function(bool enabled) onEnabledChanged;
  final Future<void> Function(String instructions) onSaveInstructions;
  final Future<void> Function() onResetInstructions;

  @override
  State<TranscriptCorrectionSettings> createState() =>
      _TranscriptCorrectionSettingsState();
}

final class _TranscriptCorrectionSettingsState
    extends State<TranscriptCorrectionSettings> {
  final _formKey = GlobalKey<FormState>();
  final _focusNode = FocusNode();
  late final TextEditingController _instructions;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _instructions = TextEditingController(text: widget.config.instructions);
  }

  @override
  void didUpdateWidget(TranscriptCorrectionSettings oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_focusNode.hasFocus &&
        widget.config.instructions != _instructions.text) {
      _instructions.text = widget.config.instructions;
    }
  }

  @override
  void dispose() {
    _instructions.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving || !(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    setState(() => _saving = true);
    try {
      await widget.onSaveInstructions(_instructions.text);
      _focusNode.unfocus();
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('Transcript correction', style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(
          'Gemma 4 E4B corrects each saved Parakeet transcript in a separate '
          'Android process. The original text is always preserved.',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Correct new transcripts'),
          subtitle: const Text(
            'GPU only; correction stays pending if the verified model or GPU '
            'runtime is unavailable.',
          ),
          value: widget.config.enabled,
          onChanged: disabled
              ? null
              : (enabled) => widget.onEnabledChanged(enabled),
        ),
        const SizedBox(height: 8),
        Form(
          key: _formKey,
          child: TextFormField(
            controller: _instructions,
            focusNode: _focusNode,
            minLines: 4,
            maxLines: 8,
            maxLength: TranscriptCorrectionConfig.maximumInstructionCharacters,
            enabled: !disabled,
            decoration: const InputDecoration(
              labelText: 'LLM instructions',
              alignLabelWithHint: true,
              helperText:
                  'Saved to the selected shared folder when available, with '
                  'a private fallback.',
            ),
            validator: (value) {
              try {
                TranscriptCorrectionConfig.validateInstructions(value ?? '');
                return null;
              } on FormatException catch (error) {
                return error.message;
              }
            },
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
          'Gemma ${widget.runtimeState} · '
          '${widget.provider ?? 'gpu'} · '
          '${widget.pendingCount} pending · ${widget.completedCount} corrected',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        Text(
          'Saving changes affects the next transcription. The app and model '
          'do not need to restart.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            FilledButton(
              onPressed: disabled ? null : _save,
              child: Text(_saving ? 'Saving…' : 'Save instructions'),
            ),
            OutlinedButton(
              onPressed: disabled ? null : widget.onResetInstructions,
              child: const Text('Reset instructions'),
            ),
          ],
        ),
      ],
    );
  }
}
