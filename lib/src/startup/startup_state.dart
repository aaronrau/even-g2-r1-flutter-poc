enum StartupPhase {
  starting,
  storage,
  decoder,
  vad,
  transcription,
  ready,
  degraded,
  failed,
}

final class StartupSnapshot {
  const StartupSnapshot({
    required this.phase,
    required this.message,
    this.provider,
    this.recoverable = false,
  });

  const StartupSnapshot.starting()
    : phase = StartupPhase.starting,
      message = 'Starting local audio system…',
      provider = null,
      recoverable = false;

  final StartupPhase phase;
  final String message;
  final String? provider;
  final bool recoverable;

  bool get isReady => phase == StartupPhase.ready;
  bool get isBusy =>
      phase != StartupPhase.ready &&
      phase != StartupPhase.degraded &&
      phase != StartupPhase.failed;
  bool get hasError =>
      phase == StartupPhase.degraded || phase == StartupPhase.failed;
}
