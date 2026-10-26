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
