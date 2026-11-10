import 'dart:io';

import 'package:ai_orchestrator/features/local_ai/data/services/bundled_model_registry_service.dart';
import 'package:ai_orchestrator/features/local_ai/data/services/model_download_service.dart';
import 'package:ai_orchestrator/features/local_ai/domain/entities/ai_model.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeFilePicker extends Mock implements FilePicker {}

class _EmptyCatalog extends BundledModelRegistryService {
  const _EmptyCatalog();

  @override
  Future<List<Map<String, dynamic>>> loadCatalog() async => [];
}

class _DocumentsPath extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _DocumentsPath(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

AiModel _model(String id, String path,
    {String source = 'local_import', String fileName = 'chimera.gguf'}) {
  return AiModel(
    id: id, displayName: id, fileName: fileName,
    downloadUrl: '', version: 'test', sizeBytes: 8,
    description: 'test', isDownloaded: true, localPath: path,
    source: source,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late PathProviderPlatform originalProvider;
  late ModelDownloadService service;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    root = await Directory.systemTemp.createTemp('aivexus-model-remove-');
    originalProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _DocumentsPath(root.path);
    service = ModelDownloadService(
      filePicker: _FakeFilePicker(),
      bundledModelRegistryService: const _EmptyCatalog(),
    );
  });

  tearDown(() async {
    PathProviderPlatform.instance = originalProvider;
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('removing imported GGUF unregisters but preserves original bytes', () async {
    final external = File(root.path + '/user-file/chimera.gguf');
    await external.parent.create(recursive: true);
    await external.writeAsBytes([0x47, 0x47, 0x55, 0x46, 1, 2]);
    final imported = _model('import_chimera', external.path);
    await service.saveImportedModelEntry(imported);

    await service.deleteModel(imported);

    expect((await service.loadImportedModelEntries()), isEmpty);
    expect(await external.readAsBytes(), [0x47, 0x47, 0x55, 0x46, 1, 2]);
  });

  test('active model cannot be removed', () async {
    final external = File(root.path + '/user-file/chimera.gguf');
    await external.parent.create(recursive: true);
    await external.writeAsBytes([0x47, 0x47, 0x55, 0x46]);
    final imported = _model('import_chimera', external.path);
    await service.saveImportedModelEntry(imported);
    await service.saveSelectedModel(imported.id);

    await expectLater(service.deleteModel(imported), throwsStateError);

    expect((await service.loadImportedModelEntries()).single.id, imported.id);
    expect(await external.exists(), isTrue);
  });

  test('custom URL GGUF removal frees only app-owned private file', () async {
    final managed = File(root.path + '/models/custom.gguf');
    await managed.parent.create(recursive: true);
    await managed.writeAsBytes([0x47, 0x47, 0x55, 0x46, 1, 2]);
    final custom = _model('custom_gguf', managed.path,
        source: 'custom_url', fileName: 'custom.gguf');
    await service.saveCustomModelEntry(custom);

    await service.deleteModel(custom);

    expect(await managed.exists(), isFalse);
    expect(await service.loadCustomModelEntries(), isEmpty);
  });

  test('file-name traversal is refused without deleting outside files', () async {
    final outside = File(root.path + '/outside.gguf');
    await outside.writeAsBytes([0x47, 0x47, 0x55, 0x46]);
    final malicious = _model('bad_model', outside.path,
        source: 'custom_url', fileName: '../outside.gguf');

    await expectLater(service.deleteModel(malicious), throwsException);
    expect(await outside.exists(), isTrue);
  });

  test('shared managed GGUF is never deleted while referenced twice', () async {
    final managed = File(root.path + '/models/shared.gguf');
    await managed.parent.create(recursive: true);
    await managed.writeAsBytes([0x47, 0x47, 0x55, 0x46, 1, 2]);
    final first = _model('custom_one', managed.path,
        source: 'custom_url', fileName: 'shared.gguf');
    final second = _model('custom_two', managed.path,
        source: 'custom_url', fileName: 'shared.gguf');
    await service.saveCustomModelEntry(first);
    await service.saveCustomModelEntry(second);

    await expectLater(service.deleteModel(first), throwsStateError);
    expect(await managed.exists(), isTrue);
    expect((await service.loadCustomModelEntries()).length, 2);
  });
}
