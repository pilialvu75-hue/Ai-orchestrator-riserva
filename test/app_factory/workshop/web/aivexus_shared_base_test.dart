import 'dart:convert';
import 'dart:typed_data';

import 'package:ai_orchestrator/app_factory/workshop/domains/shared/aivexus_attachment_store.dart';
import 'package:ai_orchestrator/app_factory/workshop/domains/shared/aivexus_project_extension.dart';
import 'package:ai_orchestrator/app_factory/workshop/domains/shared/aivexus_resource_exchange.dart';
import 'package:ai_orchestrator/app_factory/workshop/web/workshop_web_project_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'aivexus_test_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const key = 'workshop.web.projects.v1';
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  test(
    'legacy projects keep identity, unknown fields, and exact recovery copy',
    () async {
      final legacy = aivexusProject('legacy').toJson()
        ..remove('storageRevision');
      legacy['futureMetadata'] = {
        'retain': [1, 2, 3],
      };
      final original = jsonEncode({
        'version': 1,
        'projects': [legacy],
        'futureEnvelope': true,
      });
      SharedPreferences.setMockInitialValues({key: original});
      final store = await WorkshopWebProjectStorage.open();
      final loaded = (await store.loadAll()).single;
      expect(loaded.projectKind, AivexusProjectKind.software);
      final saved = await store.saveProject(loaded.copyWith(title: 'Edited'));
      expect(saved.id, loaded.id);
      expect(saved.createdAt, loaded.createdAt);
      expect(saved.storageRevision, 1);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(WorkshopWebProjectStorage.backupKey), original);
      final envelope = jsonDecode(prefs.getString(key)!) as Map;
      expect(envelope['futureEnvelope'], true);
      expect(
        (envelope['projects'] as List).single['futureMetadata'],
        legacy['futureMetadata'],
      );
    },
  );

  test(
    'more than 100 projects survive and saving a subset does not delete others',
    () async {
      final store = await WorkshopWebProjectStorage.open();
      await store.save(List.generate(105, (i) => aivexusProject('p$i')));
      final before = await store.loadAll();
      expect(before, hasLength(105));
      await store.save([before.first.copyWith(title: 'Changed')]);
      expect(await store.loadAll(), hasLength(105));
    },
  );

  test(
    'concurrent writers merge different projects and reject stale updates',
    () async {
      final first = await WorkshopWebProjectStorage.open();
      final second = await WorkshopWebProjectStorage.open();
      await Future.wait([
        first.saveProject(aivexusProject('a')),
        second.saveProject(aivexusProject('b')),
      ]);
      expect((await first.loadAll()).map((p) => p.id), containsAll(['a', 'b']));
      final stale = (await second.loadAll()).firstWhere((p) => p.id == 'a');
      await first.saveProject(stale.copyWith(title: 'First edit'));
      await expectLater(
        second.saveProject(stale.copyWith(title: 'Lost edit')),
        throwsA(isA<WorkshopWebProjectConflict>()),
      );
      expect(
        (await second.loadAll()).firstWhere((p) => p.id == 'a').title,
        'First edit',
      );
    },
  );

  test('retrying the same creation is idempotent', () async {
    final store = await WorkshopWebProjectStorage.open();
    final draft = aivexusProject('same');
    final once = await store.saveProject(draft);
    final twice = await store.saveProject(draft);
    expect(twice.storageRevision, once.storageRevision);
    expect(await store.loadAll(), hasLength(1));
  });

  test(
    'corrupt archive is not mistaken for an empty archive or overwritten',
    () async {
      const original = '{"version":1,"projects":[';
      SharedPreferences.setMockInitialValues({key: original});
      final store = await WorkshopWebProjectStorage.open();
      await expectLater(store.loadAll(), throwsFormatException);
      await expectLater(
        store.saveProject(aivexusProject('new')),
        throwsFormatException,
      );
      expect((await SharedPreferences.getInstance()).getString(key), original);
    },
  );

  test(
    'unknown extensions remain readable and cannot be edited away',
    () async {
      final future = aivexusProject('future').toJson();
      future['extension'] = {
        'schemaVersion': 2,
        'projectKind': 'cad',
        'newField': [1, 2],
      };
      SharedPreferences.setMockInitialValues({
        key: jsonEncode({
          'version': 1,
          'projects': [future],
        }),
      });
      final store = await WorkshopWebProjectStorage.open();
      final unknown = (await store.loadAll()).single;
      expect(unknown.isReadOnly, true);
      await expectLater(
        store.saveProject(unknown.copyWith(title: 'Unsafe')),
        throwsStateError,
      );
      await store.saveProject(aivexusProject('unrelated'));
      expect(
        (await store.loadAll())
            .firstWhere((p) => p.id == 'future')
            .extension!
            .toJson(),
        future['extension'],
      );
    },
  );

  test(
    'CAD/game round-trip, revision change retains stale artifacts in history',
    () async {
      final store = await WorkshopWebProjectStorage.open();
      final initial = AivexusProjectExtension.draft(AivexusProjectKind.cad);
      final cadData = Map<String, Object?>.from(initial.toJson()! as Map);
      cadData['artifacts'] = [aivexusArtifact()];
      final cad = await store.saveProject(
        aivexusProject(
          'cad',
          extension: AivexusProjectExtension.validated(cadData),
        ),
      );
      await store.saveProject(
        aivexusProject(
          'game',
          extension: AivexusProjectExtension.draft(AivexusProjectKind.game),
        ),
      );
      final revised = cad.extension!.revise(
        domainSpec: {
          ...cad.extension!.domainSpec,
          'parameters': {'width': 65},
        },
      );
      expect(revised.specRevision, 2);
      expect(revised.currentArtifacts, isEmpty);
      final saved = await store.saveProject(cad.copyWith(extension: revised));
      final reopened = await WorkshopWebProjectStorage.open();
      final loaded = (await reopened.loadAll()).firstWhere(
        (p) => p.id == 'cad',
      );
      expect(loaded.extension!.toJson(), saved.extension!.toJson());
      expect((loaded.extension!.toJson()! as Map)['artifacts'], hasLength(1));
      final illegal = Map<String, Object?>.from(revised.toJson()! as Map)
        ..['artifacts'] = <Object?>[];
      await expectLater(
        store.saveProject(
          saved.copyWith(extension: AivexusProjectExtension.validated(illegal)),
        ),
        throwsStateError,
      );
    },
  );

  test('photo drafts require immutable photo references and reject malformed hashes', () {
    final data = Map<String, Object?>.from(
      AivexusProjectExtension.draft(AivexusProjectKind.cad).toJson()! as Map,
    );
    (data['domainSpec'] as Map)['inputMode'] = 'photo_reference';
    expect(
      () => AivexusProjectExtension.validated(data),
      throwsFormatException,
    );
    data['inputs'] = [
      {
        'ref': 'photo:1',
        'name': 'photo.jpg',
        'role': 'photo',
        'mimeType': 'image/jpeg',
        'sizeBytes': 3,
        'sha256': aivexusFixtureHash,
      },
    ];
    expect(AivexusProjectExtension.validated(data).isReadOnly, false);
    ((data['inputs'] as List).single as Map)['sha256'] = 'unverified';
    expect(
      () => AivexusProjectExtension.validated(data),
      throwsFormatException,
    );
  });

  test(
    'binary attachments stay separate and consumers verify hash and size',
    () async {
      final backend = InMemoryAivexusBlobStorage();
      final producer = AivexusAttachmentStore(backend);
      final bytes = Uint8List.fromList([1, 2, 3]);
      final ref = await producer.put(
        bytes: bytes,
        name: 'photo.bin',
        role: 'photo',
        mimeType: 'application/octet-stream',
      );
      bytes[0] = 9;
      final consumer = AivexusAttachmentStore(backend);
      expect(await consumer.readVerified(ref), [1, 2, 3]);
      expect(ref.keys, isNot(contains('bytes')));
      await expectLater(
        consumer.readVerified({...ref, 'sizeBytes': 5}),
        throwsStateError,
      );
      await expectLater(
        AivexusAttachmentStore(_CorruptBlobs()).readVerified(ref),
        throwsStateError,
      );
    },
  );

  test('exchange retry retains progress; produced output requires persisted lineage', () async {
    final store = await WorkshopWebProjectStorage.open();
    await store.saveProject(
      aivexusProject(
        'consumer',
        extension: AivexusProjectExtension.draft(AivexusProjectKind.game),
      ),
    );
    final producer = Map<String, Object?>.from(
      AivexusProjectExtension.draft(AivexusProjectKind.cad).toJson()! as Map,
    )..['artifacts'] = [aivexusArtifact()];
    await store.saveProject(
      aivexusProject(
        'producer',
        extension: AivexusProjectExtension.validated(producer),
      ),
    );
    final request = AivexusResourceExchange.request(aivexusRequest('consumer'));
    final saved = await store.saveResourceExchange(request);
    final accepted = await store.saveResourceExchange(
      saved.transition('accepted'),
    );
    final retry = await store.saveResourceExchange(request);
    expect(retry.status, 'accepted');
    expect(retry.recordRevision, accepted.recordRevision);
    final wrong = accepted.transition(
      'produced',
      producedResult: {
        ...aivexusResult('producer'),
        'sha256': List.filled(64, 'b').join(),
      },
    );
    await expectLater(store.saveResourceExchange(wrong), throwsStateError);
    final mislabeled = accepted.transition(
      'produced',
      producedResult: {...aivexusResult('producer'), 'mimeType': 'model/stl'},
    );
    await expectLater(store.saveResourceExchange(mislabeled), throwsStateError);
    final produced = await store.saveResourceExchange(
      accepted.transition(
        'produced',
        producedResult: aivexusResult('producer'),
      ),
    );
    expect(produced.status, 'produced');
    final reopened = await WorkshopWebProjectStorage.open();
    expect(
      (await reopened.loadResourceExchanges()).single.toJson(),
      produced.toJson(),
    );
    expect(() => produced.transition('requested'), throwsStateError);
    await expectLater(
      store.saveResourceExchange(
        AivexusResourceExchange.request({
          ...aivexusRequest('consumer'),
          'requestedFormat': 'STL',
        }),
      ),
      throwsStateError,
    );
  });

  test(
    'an artifact reference cannot be reassigned to different output bytes',
    () {
      final data =
          Map<String, Object?>.from(
              AivexusProjectExtension.draft(AivexusProjectKind.cad).toJson()!
                  as Map,
            )
            ..['artifacts'] = [
              aivexusArtifact(),
              {...aivexusArtifact(), 'sha256': List.filled(64, 'b').join()},
            ];
      expect(
        () => AivexusProjectExtension.validated(data),
        throwsFormatException,
      );
    },
  );
}

final class _CorruptBlobs implements AivexusBlobStorage {
  @override
  Future<void> putIfAbsent(String sha256, Uint8List bytes) async {}
  @override
  Future<Uint8List?> read(String sha256) async => Uint8List.fromList([3, 2, 1]);
}
