import 'package:shared_preferences/shared_preferences.dart';

import 'speech_model.dart';

const speechModelPreferenceKey = 'speech_model_id';

final class SpeechModelPreferences {
  const SpeechModelPreferences();

  Future<SpeechModelDefinition> load() async {
    final preferences = await SharedPreferences.getInstance();
    final stored = speechModelForId(
      preferences.getString(speechModelPreferenceKey),
    );
    return stored ?? defaultSpeechModel();
  }

  Future<void> save(SpeechModelDefinition model) async {
    final preferences = await SharedPreferences.getInstance();
    final saved = await preferences.setString(
      speechModelPreferenceKey,
      model.id,
    );
    if (!saved) {
      throw StateError('Could not save the transcription model setting.');
    }
  }
}
