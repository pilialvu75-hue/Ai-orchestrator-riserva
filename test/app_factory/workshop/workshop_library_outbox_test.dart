import 'dart:convert';

import 'package:ai_orchestrator/app_factory/workshop/workshop_library_intake_bridge.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_library_outbox.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('emits deterministic credential-free intake envelope', () async {
    WorkshopLibraryOutboxEnvelope? captured;
    final transport = WorkshopLibraryOutboxTransport(
      write: (envelope) async {
        captured = envelope;
        return 'outbox://voice.turn_taking@1.2.0';
      },
    );

    final receipt = await transport.submit(
      const WorkshopLibraryTransportRequest(
        repository: 'pilialvu75-hue/AI-Orchestrator-Module-Library',
        pin: 'voice.turn_taking@1.2.0',
        manifestPath: 'intake/voice.turn_taking/1.2.0/manifest.json',
        manifest: <String, Object?>{
          'id': 'voice.turn_taking',
          'version': '1.2.0',
          'status': 'discovered',
        },
        payloadSha256:
            '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
        sourceProjectId: 'project-voice',
        sourceTaskId: 'task-turn-taking',
      ),
    );

    expect(receipt.accepted, isTrue);
    expect(receipt.remoteReference, 'outbox://voice.turn_taking@1.2.0');
    expect(captured, isNotNull);

    final decoded = jsonDecode(captured!.encode()) as Map<String, Object?>;
    expect(decoded['schema'], 'ai-orchestrator.library-intake-outbox.v1');
    expect(
      decoded['manifest_path'],
      'intake/voice.turn_taking/1.2.0/manifest.json',
    );
    expect(decoded.containsKey('token'), isFalse);
    expect(decoded.containsKey('authorization'), isFalse);
  });

  test('fails closed when outbox sink rejects the envelope', () async {
    final transport = WorkshopLibraryOutboxTransport(
      write: (_) async => null,
    );

    final receipt = await transport.submit(
      const WorkshopLibraryTransportRequest(
        repository: 'pilialvu75-hue/AI-Orchestrator-Module-Library',
        pin: 'voice.turn_taking@1.2.0',
        manifestPath: 'intake/voice.turn_taking/1.2.0/manifest.json',
        manifest: <String, Object?>{'status': 'discovered'},
        payloadSha256:
            '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
        sourceProjectId: 'project-voice',
        sourceTaskId: null,
      ),
    );

    expect(receipt.accepted, isFalse);
    expect(receipt.message, 'outbox-write-rejected');
  });
}
