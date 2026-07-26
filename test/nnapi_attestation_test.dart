import 'dart:io';

import 'package:even_g2_r1_poc/src/audio/nnapi_attestation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('accepts a profile with NNAPI-assigned node executions', () {
    final directory = Directory.systemTemp.createTempSync(
      'workbench-nnapi-test-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final profile = File('${directory.path}/profile.json')
      ..writeAsStringSync(
        '['
        '{"cat":"Node","dur":120,"args":'
        '{"provider":"NnapiExecutionProvider"}},'
        '{"cat":"Node","dur":30,"args":'
        '{"provider":"CPUExecutionProvider"}}'
        ']',
      );

    final result = NnapiAttestation.parseProfiles(<File>[profile]);

    expect(result.usedNnapiHardware, isTrue);
    expect(result.nnapiNodeExecutions, 1);
    expect(result.cpuNodeExecutions, 1);
    expect(result.nnapiDurationMicros, 120);
    expect(result.cpuDurationMicros, 30);
  });

  test('rejects a CPU-only profile', () {
    final directory = Directory.systemTemp.createTempSync(
      'workbench-nnapi-test-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final profile = File('${directory.path}/profile.json')
      ..writeAsStringSync(
        '[{"cat":"Node","dur":30,"args":'
        '{"provider":"CPUExecutionProvider"}}]',
      );

    final result = NnapiAttestation.parseProfiles(<File>[profile]);

    expect(result.usedNnapiHardware, isFalse);
    expect(result.rejectionReason, 'NNAPI assigned zero model nodes');
  });

  test('ignores non-node metadata without a provider', () {
    final directory = Directory.systemTemp.createTempSync(
      'workbench-nnapi-test-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final profile = File('${directory.path}/profile.json')
      ..writeAsStringSync('[{"cat":"Session","dur":10,"args":{}}]');

    final result = NnapiAttestation.parseProfiles(<File>[profile]);

    expect(result.profileCount, 1);
    expect(result.profiledNodeExecutions, 0);
    expect(
      result.rejectionReason,
      'ONNX Runtime profiling contained no provider-assigned nodes',
    );
  });
}
