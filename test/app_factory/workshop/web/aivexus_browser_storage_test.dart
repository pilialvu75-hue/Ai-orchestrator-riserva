@TestOn('browser')
library;

// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:async';
import 'dart:html' as html;
import 'dart:js' as js;
import 'dart:js_interop';
import 'dart:js_util' as js_util;
import 'dart:typed_data';

import 'package:ai_orchestrator/app_factory/workshop/web/workshop_web_attachment_storage.dart';
import 'package:ai_orchestrator/app_factory/workshop/web/workshop_web_project_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'aivexus_test_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    // Real browser plugin, deliberately no SharedPreferences mock.
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove('workshop.web.projects.v1');
    await preferences.remove(WorkshopWebProjectStorage.backupKey);
  });

  test(
    'project write waits for a lock held by another browser context',
    () async {
      final frame = html.IFrameElement()..src = 'about:blank';
      final loaded = frame.onLoad.first;
      html.document.body!.append(frame);
      addTearDown(frame.remove);
      await loaded;
      final navigator = js_util.getProperty<Object>(
        frame.contentWindow!,
        'navigator',
      );
      final locks = js_util.getProperty<Object>(navigator, 'locks');
      final acquired = Completer<void>();
      final release = Completer<JSAny?>();
      addTearDown(() {
        if (!release.isCompleted) release.complete(null);
      });
      final blocked = js_util.callMethod<Object>(locks, 'request', [
        'workshop.web.projects.v1',
        js.allowInterop((Object? _) {
          acquired.complete();
          return release.future.toJS;
        }),
      ]);
      await acquired.future;
      final store = await WorkshopWebProjectStorage.open();
      var saved = false;
      final writing = store
          .saveProject(aivexusProject('browser-a'))
          .then((_) => saved = true);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(
        saved,
        false,
        reason: 'A local-only mutex cannot protect another context',
      );
      release.complete(null);
      await js_util.promiseToFuture<Object?>(blocked);
      await writing;
      expect(saved, true);
      expect(
        html.window.localStorage.keys.any(
          (key) => key.contains('workshop.web.projects.v1'),
        ),
        true,
      );
      final second = await WorkshopWebProjectStorage.open();
      final previous = (await second.loadAll()).single;
      await store.saveProject(
        previous.copyWith(title: 'Current browser revision'),
      );
      await expectLater(
        second.saveProject(previous.copyWith(title: 'Stale tab')),
        throwsA(isA<WorkshopWebProjectConflict>()),
      );
    },
  );

  test(
    'IndexedDB attachment bytes survive reopening and verify at consumption',
    () async {
      final first = await WorkshopWebAttachmentStorage.open();
      final reference = await first.put(
        bytes: Uint8List.fromList([23, 42, 11]),
        name: 'fixture.bin',
        role: 'other',
        mimeType: 'application/octet-stream',
      );
      final reopened = await WorkshopWebAttachmentStorage.open();
      expect(await reopened.readVerified(reference), [23, 42, 11]);
      await expectLater(
        reopened.readVerified({...reference, 'sizeBytes': 4}),
        throwsStateError,
      );
    },
  );
}
