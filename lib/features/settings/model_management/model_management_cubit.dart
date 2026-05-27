import 'package:dio/dio.dart';
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
  final Map<String, CancelToken> _downloadCancelTokens = <String, CancelToken>{};

  void _emitIfOpen(ModelManagementState nextState) {
    if (isClosed) return;
    emit(nextState);
  }

  Future<void> scanIntegrity() async {
    _emitIfOpen(state.copyWith(scanning: true));
    final inspections = await _service.inspectAll();
    if (isClosed) return;
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
    _emitIfOpen(state.copyWith(repairingAll: true));
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
      if (isClosed) break;
      await _downloadOne(file);
    }
    _emitIfOpen(state.copyWith(repairingAll: false));
  }

  Future<void> exportAllModelsToPublicStorage() async {
    _emitIfOpen(
      state.copyWith(
        exportingAll: true,
        exportProgress: 0,
        clearExportMessage: true,
      ),
    );
    try {
      await _service.exportAllRuntimeModels(
        onProgress: (progress) {
          _emitIfOpen(
            state.copyWith(
              exportingAll: true,
              exportProgress: progress,
            ),
          );
        },
      );
      _emitIfOpen(
        state.copyWith(
          exportingAll: false,
          exportProgress: 1,
          exportMessage:
              'Esportazione completata! Ora puoi disinstallare l’app in sicurezza.',
        ),
      );
      await scanIntegrity();
    } on ModelDownloadFailureException catch (error) {
      _emitIfOpen(
        state.copyWith(
          exportingAll: false,
          exportProgress: 0,
          exportMessage: error.message,
        ),
      );
    } catch (error) {
      _emitIfOpen(
        state.copyWith(
          exportingAll: false,
          exportProgress: 0,
          exportMessage: 'Esportazione fallita: $error',
        ),
      );
    }
  }

  Future<void> _downloadOne(RuntimeModelFileSpec spec) async {
    if (_downloadCancelTokens.containsKey(spec.id)) {
      return;
    }
    final cancelToken = CancelToken();
    _downloadCancelTokens[spec.id] = cancelToken;
    _emitIfOpen(
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
        cancelToken: cancelToken,
        onProgress: (progress) {
          if (isClosed || !_downloadCancelTokens.containsKey(spec.id)) return;
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
      _emitIfOpen(
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
      _emitIfOpen(
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
      _emitIfOpen(
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
    } finally {
      _downloadCancelTokens.remove(spec.id);
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

  @override
  Future<void> close() async {
    for (final entry in _downloadCancelTokens.entries) {
      entry.value.cancel('ModelManagementCubit closed');
    }
    _downloadCancelTokens.clear();
    return super.close();
  }
}
