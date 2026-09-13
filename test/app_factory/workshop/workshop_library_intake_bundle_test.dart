import 'dart:convert';

import 'package:ai_orchestrator/app_factory/workshop/workshop_library_intake_bundle.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_library_submission.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('WorkshopLibraryIntakeBundle', () {
    test('builds a deterministic bundle from real payload bytes', () {
      final files = <WorkshopLibraryIntakePayloadFile>[
        WorkshopLibraryIntakePayloadFile(
          path: 'lib/z.dart',
          bytes: utf8.encode('z'),
        ),
        WorkshopLibraryIntakePayloadFile(
          path: 'lib/a.dart',
          bytes: utf8.encode('a'),
        ),
      ];
      final digest = WorkshopLibraryIntakeBundle.computePayloadSha256(files);
      final submission = _submission(payloadSha256: digest);

      final first = WorkshopLibraryIntakeBundle.build(
        submission: submission,
        files: files,
      );
      final second = WorkshopLibraryIntakeBundle.build(
        submission: submission,
        files: files.reversed,
      );

      expect(first.payloadSha256, digest);
      expect(second.payloadJson, first.payloadJson);
      expect(second.bundleJson, first.bundleJson);
      expect(second.bundleSha256, first.bundleSha256);

      final payload = jsonDecode(first.payloadJson) as Map<String, dynamic>;
      final encodedFiles = payload['files'] as List<dynamic>;
      expect((encodedFiles[0] as Map<String, dynamic>)['path'], 'lib/a.dart');
      expect(
        utf8.decode(
          base64Decode(
            (encodedFiles[0] as Map<String, dynamic>)['content_base64'] as String,
          ),
        ),
        'a',
      );
      expect((encodedFiles[1] as Map<String, dynamic>)['path'], 'lib/z.dart');
    });

    test('rejects payload bytes that do not match the accepted submission digest', () {
      final files = <WorkshopLibraryIntakePayloadFile>[
        WorkshopLibraryIntakePayloadFile(
          path: 'lib/module.dart',
          bytes: utf8.encode('actual'),
        ),
      ];

      expect(
        () => WorkshopLibraryIntakeBundle.build(
          submission: _submission(payloadSha256: '0' * 64),
          files: files,
        ),
        throwsStateError,
      );
    });

    test('rejects unsafe and credential-like payload paths', () {
      for (final path in <String>[
        '../outside.dart',
        '/absolute.dart',
        r'lib\windows.dart',
        '.git/config',
        'build/output.txt',
        '.env',
        'android/key.properties',
        'signing/release.jks',
      ]) {
        expect(
          () => WorkshopLibraryIntakeBundle.computePayloadSha256(
            <WorkshopLibraryIntakePayloadFile>[
              WorkshopLibraryIntakePayloadFile(path: path, bytes: const <int>[1]),
            ],
          ),
          throwsArgumentError,
          reason: path,
        );
      }
    });

    test('rejects duplicate payload paths and empty payloads', () {
      expect(
        () => WorkshopLibraryIntakeBundle.computePayloadSha256(
          const <WorkshopLibraryIntakePayloadFile>[],
        ),
        throwsArgumentError,
      );

      expect(
        () => WorkshopLibraryIntakeBundle.computePayloadSha256(
          <WorkshopLibraryIntakePayloadFile>[
            WorkshopLibraryIntakePayloadFile(
              path: 'lib/a.dart',
              bytes: const <int>[1],
            ),
            WorkshopLibraryIntakePayloadFile(
              path: 'lib/a.dart',
              bytes: const <int>[2],
            ),
          ],
        ),
        throwsArgumentError,
      );
    });

    test('bundle contains no credential field and remains discovered intake', () {
      final files = <WorkshopLibraryIntakePayloadFile>[
        WorkshopLibraryIntakePayloadFile(
          path: 'lib/module.dart',
          bytes: utf8.encode('module'),
        ),
      ];
      final digest = WorkshopLibraryIntakeBundle.computePayloadSha256(files);
      final bundle = WorkshopLibraryIntakeBundle.build(
        submission: _submission(payloadSha256: digest),
        files: files,
      );

      final decoded = jsonDecode(bundle.bundleJson) as Map<String, dynamic>;
      expect(decoded['schema'], 'ai-orchestrator.library-intake-bundle.v1');
      expect(decoded['manifest_path'], 'intake/demo.asset/1.0.0/manifest.json');
      expect((decoded['manifest'] as Map<String, dynamic>)['status'], 'discovered');
      expect(decoded.containsKey('token'), isFalse);
      expect(decoded.containsKey('authorization'), isFalse);
      expect(decoded.containsKey('credential'), isFalse);
    });
  });
}

WorkshopLibraryIntakeSubmission _submission({required String payloadSha256}) {
  return WorkshopLibraryIntakeSubmission(
    assetId: 'demo.asset',
    version: '1.0.0',
    manifest: <String, Object?>{
      'id': 'demo.asset',
      'version': '1.0.0',
      'status': 'discovered',
      'payload': <String, Object?>{
        'type': 'archive',
        'sha256': payloadSha256,
      },
    },
    sourceProjectId: 'project-1',
    sourceTaskId: 'task-1',
    payloadSha256: payloadSha256,
  );
}
