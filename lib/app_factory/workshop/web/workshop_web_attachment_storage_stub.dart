import '../domains/shared/aivexus_attachment_store.dart';

abstract final class WorkshopWebAttachmentStorage {
  static Future<AivexusAttachmentStore> open() => Future.error(
    UnsupportedError('Persistent Web attachments require a browser.'),
  );
}
