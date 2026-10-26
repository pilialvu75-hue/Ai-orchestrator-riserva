import 'dart:io';

import 'package:ai_orchestrator/features/multimodal/data/services/file_attachment_service.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _VideoFilePicker extends Mock implements FilePicker {}

void main() {
  test('Video opens the system file picker without broad storage permissions',
      () async {
    final dir = await Directory.systemTemp.createTemp('video-picker-test-');
    try {
      final source = File('${dir.path}/clip.mp4');
      await source.writeAsBytes(const <int>[1, 2, 3]);
      final picker = _VideoFilePicker();
      when(() => picker.pickFiles(
            allowMultiple: false,
            withData: false,
            type: FileType.video,
          )).thenAnswer(
        (_) async => FilePickerResult(
          <PlatformFile>[
            PlatformFile(
              name: 'clip.mp4',
              size: 3,
              path: source.path,
            ),
          ],
        ),
      );

      final chosen = await FileAttachmentService(
        filePicker: picker,
      ).pickVideo();

      expect(chosen, isNotNull);
      expect(chosen!.path, source.path);
      expect(chosen.mimeType, 'video/mp4');
      verify(() => picker.pickFiles(
            allowMultiple: false,
            withData: false,
            type: FileType.video,
          )).called(1);
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('Video picker cancellation is harmless', () async {
    final picker = _VideoFilePicker();
    when(() => picker.pickFiles(
          allowMultiple: false,
          withData: false,
          type: FileType.video,
        )).thenAnswer((_) async => null);
    expect(
      await FileAttachmentService(filePicker: picker).pickVideo(),
      isNull,
    );
  });
}
