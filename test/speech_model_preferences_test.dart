import 'package:even_g2_r1_poc/src/audio/speech_model.dart';
import 'package:even_g2_r1_poc/src/audio/speech_model_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const store = SpeechModelPreferences();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('uses the larger Parakeet model when no preference exists', () async {
    expect(await store.load(), same(parakeet06bModel));
  });

  test('persists and restores the selected model', () async {
    await store.save(tinyWhisperModel);

    expect(await store.load(), same(tinyWhisperModel));
  });

  test('falls back safely when a stored model id is unknown', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      speechModelPreferenceKey: 'removed-model',
    });

    expect(await store.load(), same(parakeet06bModel));
  });
}
