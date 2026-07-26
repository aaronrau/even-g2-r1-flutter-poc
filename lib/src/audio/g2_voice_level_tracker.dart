import 'dart:math';

/// Converts the LC3 spectral global-gain index into a display-friendly
/// speech-activity level.
///
/// This intentionally operates on LC3 side information instead of compressed
/// byte deltas. The adaptive floor keeps the graph flat around steady room
/// noise, while a fast attack and slower release make speech easy to see.
final class G2VoiceLevelTracker {
  static const double _gateIndices = 4;
  static const double _displaySpanIndices = 14;

  double? noiseFloor;
  double _smoothedLevel = 0;

  int get level => _smoothedLevel.round().clamp(0, 255);

  int addGain(int gain) {
    if (gain < 0 || gain > 255) {
      throw RangeError.range(gain, 0, 255, 'gain');
    }

    var floor = noiseFloor ?? gain.toDouble();
    if (gain < floor) {
      // Follow reductions in the ambient floor quickly.
      floor = floor * 0.65 + gain * 0.35;
    } else if (gain <= floor + 2) {
      // Learn small steady-state variations without treating them as speech.
      floor = floor * 0.995 + gain * 0.005;
    } else {
      // A permanently louder environment may recalibrate, but speech cannot
      // pull the silence floor upward during a normal utterance.
      floor += min(0.003, (gain - floor) * 0.0005);
    }
    noiseFloor = floor;

    final gainAboveFloor = gain - floor;
    final target = gainAboveFloor <= _gateIndices
        ? 0.0
        : ((gainAboveFloor - _gateIndices) / _displaySpanIndices).clamp(
                0.0,
                1.0,
              ) *
              255;
    final smoothing = target > _smoothedLevel ? 0.65 : 0.18;
    _smoothedLevel += (target - _smoothedLevel) * smoothing;
    if (target == 0 && _smoothedLevel < 4) {
      _smoothedLevel = 0;
    }
    return level;
  }

  void reset() {
    noiseFloor = null;
    _smoothedLevel = 0;
  }
}
