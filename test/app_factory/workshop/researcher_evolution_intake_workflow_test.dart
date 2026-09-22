import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../../tool/researcher_evolution_intake.dart' as intake_tool;

void main() {
  test('materializes repository-dispatch intake with Flutter runtime', () async {
    final payloadFile = Platform.environment['PAYLOAD_FILE']?.trim() ?? '';
    final intakeDir = Platform.environment['INTAKE_DIR']?.trim() ?? '';

    expect(payloadFile, isNotEmpty);
    expect(intakeDir, isNotEmpty);

    await intake_tool.main(<String>[payloadFile, intakeDir]);

    final root = Directory(intakeDir);
    final work = File('${root.path}/researcher-evolution-work.json');
    final task = File('${root.path}/workshop-task-contract.json');
    final durable = File('${root.path}/workshop-durable-project.json');

    expect(await work.exists(), isTrue);
    expect(await task.exists(), isTrue);
    expect(await durable.exists(), isTrue);

    final workJson =
        jsonDecode(await work.readAsString()) as Map<String, dynamic>;
    final taskJson =
        jsonDecode(await task.readAsString()) as Map<String, dynamic>;
    final durableJson =
        jsonDecode(await durable.readAsString()) as Map<String, dynamic>;

    expect(workJson['source_code_transferred'], isFalse);
    expect(
      taskJson['metadata']?['mutationPolicy'],
      'isolated_candidate_no_library_mutation',
    );
    expect(durableJson['state'], 'ready');
  });
}
