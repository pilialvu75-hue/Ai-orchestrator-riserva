// Keep the existing Dart 3.4 browser compatibility floor.
// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html' as html;
import 'dart:indexed_db' as idb;
import 'dart:typed_data';

import '../domains/shared/aivexus_attachment_store.dart';

abstract final class WorkshopWebAttachmentStorage {
  static Future<AivexusAttachmentStore> open() async {
    final factory = html.window.indexedDB;
    if (factory == null) throw UnsupportedError('IndexedDB non disponibile.');
    final database = await factory.open(
      'aivexus.attachments.v1',
      version: 1,
      onUpgradeNeeded: (event) {
        final database = (event.target as idb.Request).result as idb.Database;
        database.createObjectStore('blobs');
      },
    );
    database.onVersionChange.listen((_) => database.close());
    return AivexusAttachmentStore(_IndexedDbBlobs(database));
  }
}

final class _IndexedDbBlobs implements AivexusBlobStorage {
  _IndexedDbBlobs(this.database);
  final idb.Database database;

  @override
  Future<void> putIfAbsent(String digest, Uint8List bytes) async {
    final transaction = database.transaction('blobs', 'readwrite');
    final store = transaction.objectStore('blobs');
    // The read and conditional insert share one serialized transaction.
    await _complete(transaction, () async {
      if (await store.getObject(digest) == null) {
        await store.add(Uint8List.fromList(bytes), digest);
      }
    });
  }

  @override
  Future<Uint8List?> read(String digest) async {
    final transaction = database.transaction('blobs', 'readonly');
    Object? value;
    await _complete(transaction, () async {
      value = await transaction.objectStore('blobs').getObject(digest);
    });
    if (value == null) return null;
    if (value is ByteBuffer) return Uint8List.view(value! as ByteBuffer);
    if (value is List) return Uint8List.fromList((value! as List).cast<int>());
    throw StateError('Formato allegato persistito non valido.');
  }

  Future<void> _complete(
    idb.Transaction transaction,
    Future<void> Function() action,
  ) async {
    // Attach an error handler immediately, including when a request fails first.
    Object? transactionError;
    final completed = transaction.completed.then<void>(
      (_) {},
      onError: (Object error) {
        transactionError = error;
      },
    );
    try {
      await action();
      await completed;
      if (transactionError != null) throw transactionError!;
    } catch (_) {
      await completed;
      rethrow;
    }
  }
}
