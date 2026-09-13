import 'package:ai_orchestrator/app_factory/workshop/workshop_library_intake_bridge.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_library_submission.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('WorkshopLibraryIntakeBridge', () {
    test('transmits only an accepted discovered submission', () async {
      final transport = _FakeTransport();
      final bridge = WorkshopLibraryIntakeBridge(transport: transport);

      final result = await bridge.transmit(
        WorkshopLibraryCaptureDecision.accept(_submission()),
      );

      expect(result.transmitted, isTrue);
      expect(result.reasons, isEmpty);
      expect(transport.calls, 1);
      expect(transport.lastRequest!.repository,
          'pilialvu75-hue/AI-Orchestrator-Module-Library');
      expect(
        transport.lastRequest!.manifestPath,
        'intake/voice.turn_taking/1.2.0/manifest.json',
      );
      expect(transport.lastRequest!.manifest['status'], 'discovered');
    });

    test('does not call transport for rejected submission', () async {
      final transport = _FakeTransport();
      final bridge = WorkshopLibraryIntakeBridge(transport: transport);

      final result = await bridge.transmit(
        WorkshopLibraryCaptureDecision.reject(
          const <String>['tests-not-passed'],
        ),
      );

      expect(result.transmitted, isFalse);
      expect(result.reasons, contains('submission-not-accepted'));
      expect(transport.calls, 0);
    });

    test('fails closed when status is not discovered', () async {
      final transport = _FakeTransport();
      final bridge = WorkshopLibraryIntakeBridge(transport: transport);
      final submission = _submission(
        manifest: <String, Object?>{'status': 'certified'},
      );

      final result = await bridge.transmit(
        WorkshopLibraryCaptureDecision.accept(submission),
      );

      expect(result.transmitted, isFalse);
      expect(result.reasons, contains('invalid-intake-status'));
      expect(transport.calls, 0);
    });

    test('fails closed when payload digest is malformed', () async {
      final transport = _FakeTransport();
      final bridge = WorkshopLibraryIntakeBridge(transport: transport);

      final result = await bridge.transmit(
        WorkshopLibraryCaptureDecision.accept(
          _submission(payloadSha256: 'bad-digest'),
        ),
      );

      expect(result.transmitted, isFalse);
      expect(result.reasons, contains('invalid-payload-sha256'));
      expect(transport.calls, 0);
    });

    test('surfaces transport rejection without reporting success', () async {
      final transport = _FakeTransport(
        receipt: const WorkshopLibraryTransportReceipt(
          accepted: false,
          message: 'remote-intake-conflict',
        ),
      );
      final bridge = WorkshopLibraryIntakeBridge(transport: transport);

      final result = await bridge.transmit(
        WorkshopLibraryCaptureDecision.accept(_submission()),
      );

      expect(result.transmitted, isFalse);
      expect(result.reasons, contains('transport-rejected'));
      expect(result.reasons, contains('remote-intake-conflict'));
      expect(transport.calls, 1);
    });
  });
}

const String _digest =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

WorkshopLibraryIntakeSubmission _submission({
  Map<String, Object?>? manifest,
  String payloadSha256 = _digest,
}) {
  return WorkshopLibraryIntakeSubmission(
    assetId: 'voice.turn_taking',
    version: '1.2.0',
    manifest: manifest ?? <String, Object?>{'status': 'discovered'},
    sourceProjectId: 'project-voice',
    sourceTaskId: 'task-turn-taking',
    payloadSha256: payloadSha256,
  );
}

final class _FakeTransport implements WorkshopLibraryIntakeTransport {
  _FakeTransport({
    this.receipt = const WorkshopLibraryTransportReceipt(
      accepted: true,
      remoteReference: 'intake/voice.turn_taking/1.2.0',
    ),
  });

  final WorkshopLibraryTransportReceipt receipt;
  int calls = 0;
  WorkshopLibraryTransportRequest? lastRequest;

  @override
  Future<WorkshopLibraryTransportReceipt> submit(
    WorkshopLibraryTransportRequest request,
  ) async {
    calls += 1;
    lastRequest = request;
    return receipt;
  }
}
