import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:permission_handler/permission_handler.dart';

class LocalAttachmentFile {
  const LocalAttachmentFile({
    required this.path,
    required this.name,
    this.sizeBytes,
    this.mimeType,
  });

  final String path;
  final String name;
  final int? sizeBytes;
  final String? mimeType;
}

class FileAttachmentService {
  FileAttachmentService({FilePicker? filePicker})
      : _filePicker = filePicker ?? FilePicker.platform;

  final FilePicker _filePicker;

  Future<LocalAttachmentFile?> pickDocument() async {
    final result = await _filePicker.pickFiles(
      allowMultiple: false,
      withData: false,
      type: FileType.any,
    );
    return _toAttachmentFile(result);
  }

  Future<LocalAttachmentFile?> pickVideo() async {
    final granted = await _requestVideoPermission();
    if (!granted) return null;

    final result = await _filePicker.pickFiles(
      allowMultiple: false,
      withData: false,
      type: FileType.video,
    );
    return _toAttachmentFile(result, fallbackMimeType: 'video/*');
  }

  Future<bool> _requestVideoPermission() async {
    if (!Platform.isAndroid) return true;

    final videos = await Permission.videos.request();
    if (videos.isGranted || videos.isLimited) return true;

    final storage = await Permission.storage.request();
    return storage.isGranted;
  }

  LocalAttachmentFile? _toAttachmentFile(
    FilePickerResult? result, {
    String? fallbackMimeType,
  }) {
    if (result == null || result.files.isEmpty) return null;
    final file = result.files.single;
    final path = file.path;
    if (path == null || path.trim().isEmpty) return null;
    return LocalAttachmentFile(
      path: path,
      name: file.name,
      sizeBytes: file.size,
      mimeType: _resolveMimeType(file.extension, fallbackMimeType),
    );
  }

  String? _resolveMimeType(String? extension, String? fallbackMimeType) {
    final normalized = (extension ?? '').trim().toLowerCase();
    switch (normalized) {
      case 'mp4':
        return 'video/mp4';
      case 'mov':
        return 'video/quicktime';
      case 'mkv':
        return 'video/x-matroska';
      case 'webm':
        return 'video/webm';
      case 'pdf':
        return 'application/pdf';
      case 'txt':
        return 'text/plain';
      case 'json':
        return 'application/json';
      default:
        return fallbackMimeType;
    }
  }
}
