import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:ui' as ui;

/// Service providing image pick (from gallery / camera) and app-screenshot
/// capture capabilities for multimodal AI analysis.
class ImageService {
  ImageService({ImagePicker? picker}) : _picker = picker ?? ImagePicker();

  final ImagePicker _picker;

  // ── Image picking ───────────────────────────────────────────────────────────

  /// Opens the device gallery and returns the selected image file, or `null`
  /// if the user cancelled.
  Future<File?> pickFromGallery() async {
    // Android 13+ uses the OS Photo Picker, which grants access to the
    // selected image without a broad Photos/Storage permission. Requesting
    // that permission first prevented the picker from opening on devices
    // where the permission is unavailable or deliberately denied.
    // The platform picker owns consent for this single selected image.
    final xFile = await _picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 85,
    );
    return xFile == null ? null : File(xFile.path);
  }

  /// Validates a gallery image before it enters the chat composer.
  /// Read at most 12 header bytes and never log the path or the image data.
  /// LOCAL and Cloud image pipelines both currently accept at most 8 MB.
  static Future<String?> validateChatImageFile(File file) async {
    try {
      if (!await file.exists()) {
        return 'Immagine non trovata. Selezionala di nuovo.';
      }
      final size = await file.length();
      if (size == 0) {
        return 'Immagine vuota. Scegli un altro file.';
      }
      if (size > 8 * 1024 * 1024) {
        return 'Image accetta JPEG, PNG e WebP fino a 8 MB.';
      }

      final reader = await file.open();
      final List<int> header;
      try {
        header = await reader.read(12);
      } finally {
        await reader.close();
      }
      final jpeg = header.length >= 3 &&
          header[0] == 0xff &&
          header[1] == 0xd8 &&
          header[2] == 0xff;
      final png = header.length >= 8 &&
          header[0] == 0x89 &&
          header[1] == 0x50 &&
          header[2] == 0x4e &&
          header[3] == 0x47 &&
          header[4] == 0x0d &&
          header[5] == 0x0a &&
          header[6] == 0x1a &&
          header[7] == 0x0a;
      final webp = header.length >= 12 &&
          String.fromCharCodes(header.take(4)) == 'RIFF' &&
          String.fromCharCodes(header.skip(8).take(4)) == 'WEBP';
      if (!jpeg && !png && !webp) {
        return 'Formato immagine non riconosciuto. Usa JPEG, PNG o WebP.';
      }
      return null;
    } on FileSystemException {
      return 'Impossibile leggere la foto scelta. Selezionala di nuovo.';
    }
  }

  /// Opens the platform camera and returns a capture, or null on cancellation.
  ///
  /// The platform camera picker owns permission/consent. Asking for a second
  /// permission through permission_handler before opening the camera caused a
  /// silent abort on devices with restricted camera access and on platforms
  /// where a broad camera permission is not exposed.
  ///
  /// A denied permission or unsupported platform throws an explicit picker
  /// error; the chat UI displays it without sending an empty attachment.
  Future<File?> pickFromCamera() async {
    final xFile = await _picker.pickImage(
      source: ImageSource.camera,
      imageQuality: 85,
    );
    return xFile == null ? null : File(xFile.path);
  }

  // ── Screenshot ──────────────────────────────────────────────────────────────

  /// Captures the widget subtree identified by [repaintKey] as a PNG file and
  /// returns the resulting [File].
  ///
  /// Example usage in a widget:
  /// ```dart
  /// final _repaintKey = GlobalKey();
  /// RepaintBoundary(key: _repaintKey, child: myWidget)
  /// ```
  Future<File?> captureWidget(GlobalKey repaintKey) async {
    try {
      final boundary = repaintKey.currentContext?.findRenderObject()
          as RenderRepaintBoundary?;
      if (boundary == null) return null;

      final image = await boundary.toImage(pixelRatio: 2.0);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) return null;

      return await savePngBytes(
        byteData.buffer.asUint8List(),
        prefix: 'screenshot',
      );
    } catch (_) {
      return null;
    }
  }

  /// Saves raw PNG [bytes] to the app's temp directory and returns the [File].
  ///
  /// Screen Vision uses the same storage boundary as camera/gallery/widget
  /// captures so downstream chat attachments remain source-agnostic.
  Future<File> savePngBytes(
    Uint8List bytes, {
    String prefix = 'image',
  }) async {
    if (bytes.isEmpty) {
      throw ArgumentError.value(bytes, 'bytes', 'PNG bytes cannot be empty.');
    }
    final dir = await getTemporaryDirectory();
    final path =
        '${dir.path}/${prefix}_${DateTime.now().millisecondsSinceEpoch}.png';
    return File(path).writeAsBytes(bytes, flush: true);
  }

  // ── Utility ─────────────────────────────────────────────────────────────────

  /// Reads [file] and returns its bytes as a Base-64 encoded string, suitable
  /// for embedding in an AI API request.
  Future<String> fileToBase64(File file) async {
    final bytes = await file.readAsBytes();
    return base64Encode(bytes);
  }

}
