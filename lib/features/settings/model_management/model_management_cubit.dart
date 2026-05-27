import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:ai_orchestrator/core/voice/sherpa_onnx_voice_engine.dart';
import 'package:ai_orchestrator/core/voice/voice_engine.dart';
import 'package:ai_orchestrator/features/settings/model_management/model_management_service.dart';
import 'package:ai_orchestrator/features/settings/model_management/model_management_state.dart';
import 'package:ai_orchestrator/features/settings/model_management/model_runtime_manifest.dart';

class ModelManagementCubit extends Cubit<ModelManagementState> {
  ModelManagementCubit({
    required ModelManagementService service,
    required VoiceEngine voiceEngine,
    required SherpaOnnxVoiceEngine directVoiceEngine,
  })  : _service = service,
        _voiceEngine = voiceEngine,
        _directVoiceEngine = directVoiceEngine,
        super(
          ModelManagementState.initial(
            ModelRuntimeManifest.files.map((file) => file.id),
          ),
        );

  final ModelManagementService _service;
  final VoiceEngine _voiceEngine;
  final SherpaOnnxVoiceEngine _directVoiceEngine;

  Future<void> scanIntegrity() async {
    emit(state.copyWith(scanning: true));
    final inspections = await _service.inspectAll();
    emit(
      state.copyWith(
        scanning: false,
        integrityByFileId: <String, ModelFileIntegrityStatus>{
          for (final result in inspections) result.spec.id: result.status,
        },
        messageByFileId: <String, String?>{
          for (final result in inspections) result.spec.id: result.message,
        },
      ),
    );
  }

  Future<void> forceDownload(String fileId) async {
    final spec = ModelRuntimeManifest.files
        .firstWhere((element) => element.id == fileId);
    await _downloadOne(spec);
  }

  Future<void> verifyAndRepairAll() async {
    emit(state.copyWith(repairingAll: true));
    await scanIntegrity();
    final toRepair = ModelRuntimeManifest.files.where((file) {
      final integrity = state.integrityByFileId[file.id];
      return integrity == ModelFileIntegrityStatus.missing ||
          integrity == ModelFileIntegrityStatus.corrupted ||
          integrity == ModelFileIntegrityStatus.incomplete ||
          integrity == ModelFileIntegrityStatus.interrupted ||
          integrity == ModelFileIntegrityStatus.failed ||
          integrity == ModelFileIntegrityStatus.unknown;
    }).toList();

    for (final file in toRepair) {
      await _downloadOne(file);
    }
    emit(state.copyWith(repairingAll: false));
  }

  Future<void> exportAllModelsToPublicStorage() async {
    emit(
      state.copyWith(
        exportingAll: true,
        exportProgress: 0,
        clearExportMessage: true,
      ),
    );
    try {
      await _service.exportAllRuntimeModels(
        onProgress: (progress) {
          emit(
            state.copyWith(
              exportingAll: true,
              exportProgress: progress,
            ),
          );
        },
      );
      emit(
        state.copyWith(
          exportingAll: false,
          exportProgress: 1,
          exportMessage:
              'Esportazione completata! Ora puoi disinstallare l’app in sicurezza.',
        ),
      );
      await scanIntegrity();
    } on ModelDownloadFailureException catch (error) {
      emit(
        state.copyWith(
          exportingAll: false,
          exportProgress: 0,
          exportMessage: error.message,
        ),
      );
    } catch (error) {
      emit(
        state.copyWith(
          exportingAll: false,
          exportProgress: 0,
          exportMessage: 'Esportazione fallita: $error',
        ),
      );
    }
  }

  Future<void> _downloadOne(RuntimeModelFileSpec spec) async {
    emit(
      state.copyWith(
        progressByFileId: <String, double>{
          ...state.progressByFileId,
          spec.id: 0,
        },
        messageByFileId: <String, String?>{
          ...state.messageByFileId,
          spec.id: null,
        },
      ),
    );

    try {
      final inspection = await _service.forceDownload(
        spec,
        onProgress: (progress) {
          emit(
            state.copyWith(
              progressByFileId: <String, double>{
                ...state.progressByFileId,
                spec.id: progress,
              },
            ),
          );
        },
      );

      final newProgress = Map<String, double>.from(state.progressByFileId)
        ..remove(spec.id);
      emit(
        state.copyWith(
          progressByFileId: newProgress,
          integrityByFileId: <String, ModelFileIntegrityStatus>{
            ...state.integrityByFileId,
            spec.id: inspection.status,
          },
          messageByFileId: <String, String?>{
            ...state.messageByFileId,
            spec.id: null,
          },
        ),
      );
      await _notifyRuntimeBindingsReload();
    } on ModelDownloadInterruptedException catch (error) {
      final newProgress = Map<String, double>.from(state.progressByFileId)
        ..remove(spec.id);
      emit(
        state.copyWith(
          progressByFileId: newProgress,
          integrityByFileId: <String, ModelFileIntegrityStatus>{
            ...state.integrityByFileId,
            spec.id: ModelFileIntegrityStatus.interrupted,
          },
          messageByFileId: <String, String?>{
            ...state.messageByFileId,
            spec.id: error.message,
          },
        ),
      );
    } on ModelDownloadFailureException catch (error) {
      final newProgress = Map<String, double>.from(state.progressByFileId)
        ..remove(spec.id);
      emit(
        state.copyWith(
          progressByFileId: newProgress,
          integrityByFileId: <String, ModelFileIntegrityStatus>{
            ...state.integrityByFileId,
            spec.id: ModelFileIntegrityStatus.failed,
          },
          messageByFileId: <String, String?>{
            ...state.messageByFileId,
            spec.id: error.message,
          },
        ),
      );
    }
  }

  Future<void> _notifyRuntimeBindingsReload() async {
    try {
      await _voiceEngine.initialize();
    } catch (_) {}
    try {
      await _directVoiceEngine.dispose();
      await _directVoiceEngine.initialize();
    } catch (_) {}
  }
}
