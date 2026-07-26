import 'package:even_g2_r1_poc/src/audio/speech_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('defaults to the larger Parakeet 0.6B model', () {
    expect(defaultSpeechModelId, parakeet06bModel.id);
    expect(defaultSpeechModel(), same(parakeet06bModel));
    expect(availableSpeechModels.first, same(parakeet06bModel));
  });

  test('resolves every selectable speech model', () {
    expect(speechModelForId('parakeet-0.6b'), same(parakeet06bModel));
    expect(speechModelForId('parakeet-110m'), same(parakeet110mModel));
    expect(speechModelForId('tiny-whisper'), same(tinyWhisperModel));
  });

  test('rejects an unknown persisted model id', () {
    expect(speechModelForId('not-a-model'), isNull);
    expect(speechModelForId(null), isNull);
  });
}
