import 'dart:io';

import 'package:ai_orchestrator/features/multimodal/data/services/image_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mocktail/mocktail.dart';

class _MockImagePicker extends Mock implements ImagePicker {}

void main() {
  test('Image opens the platform picker without requesting storage permission',
      () async {
    final tmp = await Directory.systemTemp.createTemp('image-picker-test');
    try {
      final file = File('${tmp.path}/selected.jpg');
      await file.writeAsBytes(<int>[0xFF, 0xD8, 0xFF]);
      final picker = _MockImagePicker();
      when(() => picker.pickImage(
            source: ImageSource.gallery,
            imageQuality: 85,
          )).thenAnswer((_) async => XFile(file.path));

      final image = await ImageService(picker: picker).pickFromGallery();

      expect(image?.path, file.path);
      verify(() => picker.pickImage(
            source: ImageSource.gallery,
            imageQuality: 85,
          )).called(1);
    } finally {
      await tmp.delete(recursive: true);
    }
  });

  test('chat gallery validation accepts a valid JPEG and PNG header', () async {
    final tmp = await Directory.systemTemp.createTemp('image-chat-valid-');
    try {
      final jpeg = File('${tmp.path}/valid.jpg');
      await jpeg.writeAsBytes(const <int>[0xff, 0xd8, 0xff, 0x00]);
      expect(await ImageService.validateChatImageFile(jpeg), isNull);
      final png = File('${tmp.path}/valid.png');
      await png.writeAsBytes(const <int>[
        0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
      ]);
      expect(await ImageService.validateChatImageFile(png), isNull);
    } finally {
      await tmp.delete(recursive: true);
    }
  });

  test('chat gallery validation refuses missing, empty and renamed files', () async {
    final tmp = await Directory.systemTemp.createTemp('image-chat-bad-');
    try {
      final missing = File('${tmp.path}/missing.jpg');
      expect(await ImageService.validateChatImageFile(missing),
          contains('non trovata'));
      final empty = File('${tmp.path}/empty.png');
      await empty.create();
      expect(await ImageService.validateChatImageFile(empty),
          contains('vuota'));
      final fake = File('${tmp.path}/fake.jpg');
      await fake.writeAsString('not an actual JPEG');
      expect(await ImageService.validateChatImageFile(fake),
          contains('non riconosciuto'));
    } finally {
      await tmp.delete(recursive: true);
    }
  });

  test('chat gallery validation rejects oversize file before reading bytes',
      () async {
    final tmp = await Directory.systemTemp.createTemp('image-chat-large-');
    try {
      final file = File('${tmp.path}/big.png');
      final handle = await file.open(mode: FileMode.write);
      try {
        await handle.truncate(8 * 1024 * 1024 + 1);
      } finally {
        await handle.close();
      }
      expect(await ImageService.validateChatImageFile(file),
          contains('8 MB'));
    } finally {
      await tmp.delete(recursive: true);
    }
  });

  test('canceling the gallery picker returns null', () async {
    final picker = _MockImagePicker();
    when(() => picker.pickImage(
          source: ImageSource.gallery,
          imageQuality: 85,
        )).thenAnswer((_) async => null);

    final result = await ImageService(picker: picker).pickFromGallery();
    expect(result, isNull);
  });
}
