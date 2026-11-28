import 'dart:io';

import 'package:ai_orchestrator/core/ai/entities/ai_model.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_provider.dart';
import 'package:ai_orchestrator/features/local_ai/data/services/model_download_service.dart';
import 'package:ai_orchestrator/native/runtime/windows/windows_llama_runtime.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FilePickerMock extends Mock implements FilePicker {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('real GGUF import assigns MiniCPM5 runtime ID, persists it and passes '
      'Windows 10/11 production compatibility gate', () async {
    SharedPreferences.setMockInitialValues({});
    final tempDir = await Directory.systemTemp.createTemp('minicpm5-import-');
    addTearDown(() async => tempDir.delete(recursive: true));
    final file = File('${tempDir.path}${Platform.pathSeparator}'
        'MiniCPM5-2B-Q4_K_M.gguf');
    // Lightweight fake GGUF for import metadata; not inference evidence.
    await file.writeAsBytes(<int>[0x47, 0x47, 0x55, 0x46, 0, 0, 0, 3]);

    final picker = _FilePickerMock();
    when(() => picker.pickFiles(
          allowMultiple: false,
          withData: false,
          type: FileType.custom,
          allowedExtensions: const <String>['gguf'],
        )).thenAnswer(
      (_) async => FilePickerResult(<PlatformFile>[
        PlatformFile(
          name: 'MiniCPM5-2B-Q4_K_M.gguf',
          size: await file.length(),
          path: file.path,
        ),
      ]),
    );

    final service = ModelDownloadService(filePicker: picker);
    final imported = await service.importLocalModel();
    expect(imported, isNotNull);
    expect(imported!.id, startsWith('local_import_'));
    expect(imported.effectiveRuntimeModelId, 'minicpm5_2b');
    expect(imported.detectedFamily, 'minicpm5');
    expect(imported.platformTarget, 'windows');
    expect(imported.sizeCategory, '2B');
    expect(imported.source, 'local_import');
    expect(imported.validationStatus, ModelValidationStatus.validatedOk);

    final persisted = await service.loadImportedModelEntries();
    expect(persisted, hasLength(1));
    expect(persisted.single.id, imported.id);
    expect(persisted.single.effectiveRuntimeModelId, 'minicpm5_2b');

    final provider = LocalRuntimeProvider(developerModeProvider: () => false);
    final supported = Platform.isWindows &&
        WindowsLlamaRuntime.isModernWindows(Platform.operatingSystemVersion);
    expect(provider.supportsModel(imported), supported);
    expect(provider.supportsModel(persisted.single), supported);
    verify(() => picker.pickFiles(
          allowMultiple: false,
          withData: false,
          type: FileType.custom,
          allowedExtensions: const <String>['gguf'],
        )).called(1);
  });
}
