import 'package:shared_preferences/shared_preferences.dart';

const conversationAnalysisEnabledPreferenceKey =
    'conversation_analysis_enabled';

final class ConversationAnalysisPreferences {
  const ConversationAnalysisPreferences();

  Future<bool> loadEnabled() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getBool(conversationAnalysisEnabledPreferenceKey) ??
        false;
  }

  Future<void> saveEnabled(bool enabled) async {
    final preferences = await SharedPreferences.getInstance();
    if (!await preferences.setBool(
      conversationAnalysisEnabledPreferenceKey,
      enabled,
    )) {
      throw StateError('Could not save the speaker identification setting.');
    }
  }
}
