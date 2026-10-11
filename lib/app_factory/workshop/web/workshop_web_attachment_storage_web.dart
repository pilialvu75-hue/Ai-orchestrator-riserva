import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:ai_orchestrator/app_factory/workshop/domains/shared/aivexus_attachment_store.dart';

@JS('indexedDB')
external _Factory? get _indexedDB;

extension type _Factory(JSObject _) implements JSObject {
  external _Request open(String name, int version);
}

extension type _Request(JSObject _) implements JSObject {
  external JSAny? get result;
  external set onsuccess(JSFunction callback);
  external set onerror(JSFunction callback);
  external set onupgradeneeded(JSFunction callback);
}

extension type _Database(JSObject _) implements JSObject {
  external JSObject createObjectStore(String name);
  external _Transaction transaction(String store, String mode);
  external set onversionchange(JSFunction callback);
  external void close();
}

extension type _Transaction(JSObject _) implements JSObject {
  external _ObjectStore objectStore(String name);
  external set oncomplete(JSFunction callback);
  external set onerror(JSFunction callback);
  external set onabort(JSFunction callback);
}

extension type _ObjectStore(JSObject _) implements JSObject {
  @JS('get')
  external _Request read(String key);
  external _Request add(JSUint8Array bytes, String key);
}

Future<JSAny?> _result(_Request request) {
  final result = Completer<JSAny?>();
  request.onsuccess = ((JSAny? _) {
    if (!result.isCompleted) result.complete(request.result);
  }).toJS;
  request.onerror = ((JSAny? _) {
    if (!result.isCompleted)
      result.completeError(
        StateError('Operazione allegati IndexedDB non riuscita.'),
      );
  }).toJS;
  return result.future;
}

abstract final class WorkshopWebAttachmentStorage {
  static Future<AivexusAttachmentStore> open() async {
    final factory = _indexedDB;
    if (factory == null) throw UnsupportedError('IndexedDB non disponibile.');
    final request = factory.open('aivexus.attachments.v1', 1);
    request.onupgradeneeded = ((JSAny? _) {
      (request.result as _Database).createObjectStore('blobs');
    }).toJS;
    final database = (await _result(request)) as _Database;
    database.onversionchange = ((JSAny? _) {
      database.close();
    }).toJS;
    return AivexusAttachmentStore(_IndexedDbBlobs(database));
  }
}

final class _IndexedDbBlobs implements AivexusBlobStorage {
  _IndexedDbBlobs(this.database);
  final _Database database;

  @override
  Future<void> putIfAbsent(String digest, Uint8List bytes) async {
    final transaction = database.transaction('blobs', 'readwrite');
    final store = transaction.objectStore('blobs');
    await _complete(transaction, () async {
      if (await _result(store.read(digest)) == null) {
        await _result(store.add(Uint8List.fromList(bytes).toJS, digest));
      }
    });
  }

  @override
  Future<Uint8List?> read(String digest) async {
    final transaction = database.transaction('blobs', 'readonly');
    JSAny? value;
    await _complete(transaction, () async {
      value = await _result(transaction.objectStore('blobs').read(digest));
    });
    if (value == null) return null;
    return Uint8List.fromList((value as JSUint8Array).toDart);
  }

  Future<void> _complete(
    _Transaction transaction,
    Future<void> Function() action,
  ) async {
    // Observe the transaction before issuing requests, including aborts that
    // arrive after an individual request has already failed.
    final completed = Completer<void>();
    Object? transactionError;
    transaction.oncomplete = ((JSAny? _) {
      if (!completed.isCompleted) completed.complete();
    }).toJS;
    void failed(JSAny? _) {
      transactionError = StateError(
        'Transazione allegati non riuscita: controlla lo spazio disponibile.',
      );
      if (!completed.isCompleted) completed.complete();
    }

    transaction.onerror = failed.toJS;
    transaction.onabort = failed.toJS;
    try {
      await action();
      await completed.future;
      if (transactionError != null) throw transactionError!;
    } catch (_) {
      await completed.future;
      rethrow;
    }
  }
}
