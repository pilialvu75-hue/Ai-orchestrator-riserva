import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
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
    final granted = await _requestImagePermission();
    if (!granted) return null;

    final xFile = await _picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 85,
    );
    return xFile == null ? null : File(xFile.path);
  }

  /// Opens the device camera and returns the captured image file, or `null`
  /// if the user cancelled or denied the camera permission.
  Future<File?> pickFromCamera() async {
    final status = await Permission.camera.request();
    if (status.isDenied || status.isPermanentlyDenied) return null;

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

      return _saveBytes(byteData.buffer.asUint8List(), 'screenshot');
    } catch (_) {
      return null;
    }
  }

  /// Saves raw PNG [bytes] to the app's temp directory and returns the [File].
  Future<File> _saveBytes(Uint8List bytes, String prefix) async {
    final dir = await getTemporaryDirectory();
    final path =
        '${dir.path}/${prefix}_${DateTime.now().millisecondsSinceEpoch}.png';
    return File(path).writeAsBytes(bytes);
  }

  // ── Utility ─────────────────────────────────────────────────────────────────

  /// Reads [file] and returns its bytes as a Base-64 encoded string, suitable
  /// for embedding in an AI API request.
  Future<String> fileToBase64(File file) async {
    final bytes = await file.readAsBytes();
    return base64Encode(bytes);
  }

  Future<bool> _requestImagePermission() async {
    if (!Platform.isAndroid) {
      final status = await Permission.photos.request();
      return status.isGranted || status.isLimited;
    }

    final photos = await Permission.photos.request();
    if (photos.isGranted || photos.isLimited) return true;

    final storage = await Permission.storage.request();
    return storage.isGranted;
  }
}
