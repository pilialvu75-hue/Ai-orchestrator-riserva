import 'dart:io';

import 'package:ai_orchestrator/features/multimodal/data/services/image_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mocktail/mocktail.dart';

class _MockCameraPicker extends Mock implements ImagePicker {}

void main() {
  test('Camera invokes actual platform capture and returns a local file',
      () async {
    final directory = await Directory.systemTemp.createTemp('camera-test-');
    try {
      final captured = File('${directory.path}/captured.jpg');
      await captured.writeAsBytes(const <int>[0xFF, 0xD8, 0xFF, 0xD9]);
      final picker = _MockCameraPicker();
      when(
        () => picker.pickImage(
          source: ImageSource.camera,
          imageQuality: 85,
        ),
      ).thenAnswer((_) async => XFile(captured.path));

      final file = await ImageService(picker: picker).pickFromCamera();

      expect(file, isNotNull);
      expect(file!.path, captured.path);
      expect(await file.readAsBytes(), <int>[0xFF, 0xD8, 0xFF, 0xD9]);
      verify(
        () => picker.pickImage(
          source: ImageSource.camera,
          imageQuality: 85,
        ),
      ).called(1);
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('Camera cancellation is not treated as a photo', () async {
    final picker = _MockCameraPicker();
    when(
      () => picker.pickImage(
        source: ImageSource.camera,
        imageQuality: 85,
      ),
    ).thenAnswer((_) async => null);

    expect(await ImageService(picker: picker).pickFromCamera(), isNull);
  });

  test('Camera permission refusal is visible to the caller, not hidden',
      () async {
    final picker = _MockCameraPicker();
    when(
      () => picker.pickImage(
        source: ImageSource.camera,
        imageQuality: 85,
      ),
    ).thenThrow(
      PlatformException(
        code: 'camera_access_denied',
        message: 'Access denied',
      ),
    );

    await expectLater(
      ImageService(picker: picker).pickFromCamera(),
      throwsA(
        isA<PlatformException>().having(
          (error) => error.code,
          'code',
          'camera_access_denied',
        ),
      ),
    );
  });

  test('Camera unsupported platform remains a visible error', () async {
    final picker = _MockCameraPicker();
    when(
      () => picker.pickImage(
        source: ImageSource.camera,
        imageQuality: 85,
      ),
    ).thenThrow(UnsupportedError('No native camera on this platform'));

    await expectLater(
      ImageService(picker: picker).pickFromCamera(),
      throwsUnsupportedError,
    );
  });
}
