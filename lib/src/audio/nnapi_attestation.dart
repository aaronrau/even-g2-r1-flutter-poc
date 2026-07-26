import 'dart:convert';
import 'dart:io';

/// Execution-provider evidence collected from one silent warm-up.
final class NnapiAttestation {
  const NnapiAttestation({
    required this.profileCount,
    required this.nnapiNodeExecutions,
    required this.cpuNodeExecutions,
    required this.otherNodeExecutions,
    required this.nnapiDurationMicros,
    required this.cpuDurationMicros,
  });

  final int profileCount;
  final int nnapiNodeExecutions;
  final int cpuNodeExecutions;
  final int otherNodeExecutions;
  final int nnapiDurationMicros;
  final int cpuDurationMicros;

  int get profiledNodeExecutions =>
      nnapiNodeExecutions + cpuNodeExecutions + otherNodeExecutions;

  bool get usedNnapiHardware => nnapiNodeExecutions > 0;

  String get rejectionReason {
    if (profileCount == 0) {
      return 'ONNX Runtime did not create a profiling record';
    }
    if (profiledNodeExecutions == 0) {
      return 'ONNX Runtime profiling contained no provider-assigned nodes';
    }
    return 'NNAPI assigned zero model nodes';
  }

  static NnapiAttestation parseProfiles(Iterable<File> profiles) {
    var profileCount = 0;
    var nnapiNodes = 0;
    var cpuNodes = 0;
    var otherNodes = 0;
    var nnapiDuration = 0;
    var cpuDuration = 0;

    for (final profile in profiles) {
      final decoded = jsonDecode(profile.readAsStringSync());
      if (decoded is! List<Object?>) {
        throw const FormatException('ONNX Runtime profile is not an array.');
      }
      profileCount++;
      for (final rawEvent in decoded) {
        if (rawEvent is! Map<Object?, Object?>) {
          continue;
        }
        final rawArgs = rawEvent['args'];
        if (rawArgs is! Map<Object?, Object?>) {
          continue;
        }
        final provider = rawArgs['provider'];
        if (provider is! String || provider.isEmpty) {
          continue;
        }
        final duration = switch (rawEvent['dur']) {
          final num value => value.round(),
          _ => 0,
        };
        final normalized = provider.toLowerCase();
        if (normalized.contains('nnapi')) {
          nnapiNodes++;
          nnapiDuration += duration;
        } else if (normalized.contains('cpu')) {
          cpuNodes++;
          cpuDuration += duration;
        } else {
          otherNodes++;
        }
      }
    }

    return NnapiAttestation(
      profileCount: profileCount,
      nnapiNodeExecutions: nnapiNodes,
      cpuNodeExecutions: cpuNodes,
      otherNodeExecutions: otherNodes,
      nnapiDurationMicros: nnapiDuration,
      cpuDurationMicros: cpuDuration,
    );
  }
}

/// Creates a one-use provider config and removes raw profiles after parsing.
///
/// ONNX Runtime profiles contain graph metadata rather than captured audio, but
/// they are still kept in the app cache and never in the user's audio folder.
final class NnapiProfileProbe {
  NnapiProfileProbe._({
    required this.directory,
    required this.config,
    required this.profilePrefix,
  });

  final Directory directory;
  final File config;
  final String profilePrefix;

  String get provider => 'nnapi:${config.path}';

  static NnapiProfileProbe create({required String workload}) {
    final safeWorkload = workload.replaceAll(RegExp('[^A-Za-z0-9._-]'), '_');
    final nonce = DateTime.now().microsecondsSinceEpoch;
    final directory = Directory(
      '${Directory.systemTemp.path}/workbench-provider-profiles/'
      '$safeWorkload-$nonce',
    )..createSync(recursive: true);
    final profilePrefix = '${directory.path}/ort-profile';
    final config = File('${directory.path}/nnapi-provider.conf');
    config.writeAsStringSync(
      'ProfilingFilePrefix=$profilePrefix\n'
      'LogSeverityLevel=2\n',
      flush: true,
    );
    return NnapiProfileProbe._(
      directory: directory,
      config: config,
      profilePrefix: profilePrefix,
    );
  }

  NnapiAttestation finish() {
    try {
      final profiles =
          directory
              .listSync()
              .whereType<File>()
              .where(
                (file) =>
                    file.path.startsWith(profilePrefix) &&
                    file.path.endsWith('.json'),
              )
              .toList()
            ..sort((left, right) => left.path.compareTo(right.path));
      return NnapiAttestation.parseProfiles(profiles);
    } finally {
      if (directory.existsSync()) {
        directory.deleteSync(recursive: true);
      }
    }
  }

  void discard() {
    if (directory.existsSync()) {
      directory.deleteSync(recursive: true);
    }
  }
}
