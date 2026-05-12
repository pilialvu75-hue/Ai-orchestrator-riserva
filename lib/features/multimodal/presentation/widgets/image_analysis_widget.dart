import 'dart:io';

import 'package:flutter/material.dart';
import 'package:ai_orchestrator/features/multimodal/data/services/image_service.dart';

/// Widget that lets the user pick an image (gallery / camera) or capture a
/// screenshot, then displays a thumbnail and calls [onImageSelected].
class ImageAnalysisWidget extends StatefulWidget {
  const ImageAnalysisWidget({
    super.key,
    required this.imageService,
    this.repaintKey,
    required this.onImageSelected,
  });

  final ImageService imageService;

  /// Optional [GlobalKey] attached to a [RepaintBoundary] whose content
  /// should be captured as a screenshot.
  final GlobalKey? repaintKey;

  /// Invoked with the selected/captured [File].
  final void Function(File image) onImageSelected;

  @override
  State<ImageAnalysisWidget> createState() => _ImageAnalysisWidgetState();
}

class _ImageAnalysisWidgetState extends State<ImageAnalysisWidget> {
  File? _selectedImage;

  Future<void> _pickGallery() async {
    final file = await widget.imageService.pickFromGallery();
    if (file != null) _applyImage(file);
  }

  Future<void> _pickCamera() async {
    final file = await widget.imageService.pickFromCamera();
    if (file != null) _applyImage(file);
  }

  Future<void> _captureScreenshot() async {
    if (widget.repaintKey == null) return;
    final file = await widget.imageService.captureWidget(widget.repaintKey!);
    if (file != null) _applyImage(file);
  }

  void _applyImage(File file) {
    setState(() => _selectedImage = file);
    widget.onImageSelected(file);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Thumbnail
        if (_selectedImage != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.file(
                _selectedImage!,
                height: 160,
                width: double.infinity,
                fit: BoxFit.cover,
              ),
            ),
          ),

        // Action buttons row
        Wrap(
          spacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: _pickGallery,
              icon: const Icon(Icons.photo_library_outlined),
              label: const Text('Gallery'),
              style: OutlinedButton.styleFrom(
                foregroundColor: theme.colorScheme.primary,
              ),
            ),
            OutlinedButton.icon(
              onPressed: _pickCamera,
              icon: const Icon(Icons.camera_alt_outlined),
              label: const Text('Camera'),
              style: OutlinedButton.styleFrom(
                foregroundColor: theme.colorScheme.primary,
              ),
            ),
            if (widget.repaintKey != null)
              OutlinedButton.icon(
                onPressed: _captureScreenshot,
                icon: const Icon(Icons.screenshot_outlined),
                label: const Text('Screenshot'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: theme.colorScheme.secondary,
                ),
              ),
          ],
        ),
      ],
    );
  }
}
