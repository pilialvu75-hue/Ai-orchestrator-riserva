@TestOn('browser')
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:ai_orchestrator/app_factory/workshop/web/workshop_web_attachment_storage.dart';
import 'package:ai_orchestrator/app_factory/workshop/web/workshop_web_project_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// Exercise the real Web implementation already pinned by shared_preferences.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_web/shared_preferences_web.dart';

import 'aivexus_test_fixtures.dart';

@JS('document')
external _Document get _document;
@JS('localStorage')
external _Storage get _localStorage;

extension type _Storage(JSObject _) implements JSObject {
  external String? getItem(String key);
}

extension type _Document(JSObject _) implements JSObject {
  external _Frame createElement(String name);
  external _Element get body;
}

extension type _Element(JSObject _) implements JSObject {
  external JSObject appendChild(JSObject child);
}

extension type _Frame(JSObject _) implements JSObject {
  external set src(String value);
  external set onload(JSFunction callback);
  external _Window get contentWindow;
  external void remove();
}

extension type _Window(JSObject _) implements JSObject {
  external _Navigator get navigator;
}

extension type _Navigator(JSObject _) implements JSObject {
  external _Locks get locks;
}

extension type _Locks(JSObject _) implements JSObject {
  external JSPromise<JSAny?> request(String name, JSFunction callback);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // flutter test does not execute the application's generated plugin registrant.
  SharedPreferencesPlugin.registerWith(null);
  setUp(() async {
    // Real browser plugin, deliberately no SharedPreferences mock.
    final preferences = await SharedPreferences.getInstance().timeout(
      const Duration(seconds: 5),
      onTimeout: () =>
          throw StateError('Real Web preferences did not initialize'),
    );
    await preferences.remove('workshop.web.projects.v1');
    await preferences.remove(WorkshopWebProjectStorage.backupKey);
  });

  test(
    'project write waits for a lock held by another browser context',
    () async {
      final frame = _document.createElement('iframe');
      final loaded = Completer<void>();
      frame.onload = ((JSAny? _) {
        if (!loaded.isCompleted) loaded.complete();
      }).toJS;
      frame.src = 'about:blank';
      _document.body.appendChild(frame);
      addTearDown(() => frame.remove());
      await loaded.future.timeout(const Duration(seconds: 5));
      final acquired = Completer<void>();
      final release = Completer<JSAny?>();
      addTearDown(() {
        if (!release.isCompleted) release.complete(null);
      });
      final blocked = frame.contentWindow.navigator.locks.request(
        'workshop.web.projects.v1',
        ((JSAny? _) {
          acquired.complete();
          return release.future.toJS;
        }).toJS,
      );
      await acquired.future.timeout(const Duration(seconds: 5));
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
      await blocked.toDart;
      await writing;
      expect(saved, true);
      expect(
        _localStorage.getItem('flutter.workshop.web.projects.v1') ??
            _localStorage.getItem('workshop.web.projects.v1'),
        isNotNull,
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
