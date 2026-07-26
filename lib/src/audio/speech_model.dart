enum SpeechModelArchitecture { whisper, nemoCtc, transducer }

final class SpeechModelDefinition {
  const SpeechModelDefinition({
    required this.id,
    required this.displayName,
    required this.architecture,
    required this.tokensFile,
    required this.tokensSha256,
    this.modelFile,
    this.modelSha256,
    this.encoderFile,
    this.encoderSha256,
    this.decoderFile,
    this.decoderSha256,
    this.joinerFile,
    this.joinerSha256,
    this.bundledAssetDirectory,
  });

  final String id;
  final String displayName;
  final SpeechModelArchitecture architecture;
  final String tokensFile;
  final String tokensSha256;
  final String? modelFile;
  final String? modelSha256;
  final String? encoderFile;
  final String? encoderSha256;
  final String? decoderFile;
  final String? decoderSha256;
  final String? joinerFile;
  final String? joinerSha256;
  final String? bundledAssetDirectory;
}

const tinyWhisperModel = SpeechModelDefinition(
  id: 'tiny-whisper',
  displayName: 'Tiny Whisper',
  architecture: SpeechModelArchitecture.whisper,
  encoderFile: 'tiny.en-encoder.onnx',
  encoderSha256:
      'dc7de696432d97a3d64387800b230ac69d18e5e4efea0eec0613209dd8b7b0c9',
  decoderFile: 'tiny.en-decoder.onnx',
  decoderSha256:
      '54d5a5fd2a757175aeb70a837a8404fc9c31b659610724694f5a0e2c51715f94',
  tokensFile: 'tiny.en-tokens.txt',
  tokensSha256:
      '306cd27f03c1a714eca7108e03d66b7dc042abe8c258b44c199a7ed9838dd930',
  bundledAssetDirectory: 'assets/models/whisper',
);

const parakeet110mModel = SpeechModelDefinition(
  id: 'parakeet-110m',
  displayName: 'Parakeet 110M',
  architecture: SpeechModelArchitecture.nemoCtc,
  modelFile: 'model.int8.onnx',
  modelSha256:
      '9177a9146cf32ee0cc8152276ef95116f312018d316be37ccf57f7efea81fc1a',
  tokensFile: 'tokens.txt',
  tokensSha256:
      '450e56bd2f036fe5b6aa821865838cc5aa9d8b0106134ce9a9ba0664abe6cd10',
);

const parakeet06bModel = SpeechModelDefinition(
  id: 'parakeet-0.6b',
  displayName: 'Parakeet 0.6B',
  architecture: SpeechModelArchitecture.transducer,
  encoderFile: 'encoder.int8.onnx',
  encoderSha256:
      'acfc2b4456377e15d04f0243af540b7fe7c992f8d898d751cf134c3a55fd2247',
  decoderFile: 'decoder.int8.onnx',
  decoderSha256:
      '179e50c43d1a9de79c8a24149a2f9bac6eb5981823f2a2ed88d655b24248db4e',
  joinerFile: 'joiner.int8.onnx',
  joinerSha256:
      '3164c13fc2821009440d20fcb5fdc78bff28b4db2f8d0f0b329101719c0948b3',
  tokensFile: 'tokens.txt',
  tokensSha256:
      'd58544679ea4bc6ac563d1f545eb7d474bd6cfa467f0a6e2c1dc1c7d37e3c35d',
);

const availableSpeechModels = <SpeechModelDefinition>[
  parakeet06bModel,
  parakeet110mModel,
  tinyWhisperModel,
];

const defaultSpeechModelId = 'parakeet-0.6b';

const configuredSpeechModelId = String.fromEnvironment(
  'WORKBENCH_STT_MODEL',
  defaultValue: defaultSpeechModelId,
);

SpeechModelDefinition configuredSpeechModel() {
  final model = speechModelForId(configuredSpeechModelId);
  if (model != null) {
    return model;
  }
  throw UnsupportedError(
    'Unsupported WORKBENCH_STT_MODEL "$configuredSpeechModelId".',
  );
}

SpeechModelDefinition defaultSpeechModel() => configuredSpeechModel();

SpeechModelDefinition? speechModelForId(String? id) {
  return switch (id?.trim().toLowerCase()) {
    'tiny-whisper' || 'tiny' || 'whisper' => tinyWhisperModel,
    'parakeet-110m' || 'parakeet110m' || '110m' => parakeet110mModel,
    'parakeet-0.6b' || 'parakeet-06b' || '0.6b' => parakeet06bModel,
    _ => null,
  };
}

final class TranscriptionModelPaths {
  const TranscriptionModelPaths({
    required this.definition,
    required this.tokens,
    this.model,
    this.encoder,
    this.decoder,
    this.joiner,
  });

  final SpeechModelDefinition definition;
  final String tokens;
  final String? model;
  final String? encoder;
  final String? decoder;
  final String? joiner;

  Map<String, Object> toMessage() => <String, Object>{
    'id': definition.id,
    'displayName': definition.displayName,
    'architecture': definition.architecture.name,
    'tokens': tokens,
    'model': model ?? '',
    'encoder': encoder ?? '',
    'decoder': decoder ?? '',
    'joiner': joiner ?? '',
  };
}
