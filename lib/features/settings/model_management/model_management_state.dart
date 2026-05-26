import 'package:equatable/equatable.dart';

import 'package:ai_orchestrator/features/settings/model_management/model_management_service.dart';

class ModelManagementState extends Equatable {
  const ModelManagementState({
    required this.integrityByFileId,
    required this.progressByFileId,
    required this.messageByFileId,
    this.scanning = false,
    this.repairingAll = false,
    this.exportingAll = false,
    this.exportProgress = 0,
    this.exportMessage,
  });

  factory ModelManagementState.initial(Iterable<String> fileIds) {
    return ModelManagementState(
      integrityByFileId: <String, ModelFileIntegrityStatus>{
        for (final id in fileIds) id: ModelFileIntegrityStatus.unknown,
      },
      progressByFileId: const <String, double>{},
      messageByFileId: const <String, String?>{},
    );
  }

  final Map<String, ModelFileIntegrityStatus> integrityByFileId;
  final Map<String, double> progressByFileId;
  final Map<String, String?> messageByFileId;
  final bool scanning;
  final bool repairingAll;
  final bool exportingAll;
  final double exportProgress;
  final String? exportMessage;

  bool isDownloading(String fileId) => progressByFileId.containsKey(fileId);

  ModelManagementState copyWith({
    Map<String, ModelFileIntegrityStatus>? integrityByFileId,
    Map<String, double>? progressByFileId,
    Map<String, String?>? messageByFileId,
    bool? scanning,
    bool? repairingAll,
    bool? exportingAll,
    double? exportProgress,
    String? exportMessage,
    bool clearExportMessage = false,
  }) {
    return ModelManagementState(
      integrityByFileId: integrityByFileId ?? this.integrityByFileId,
      progressByFileId: progressByFileId ?? this.progressByFileId,
      messageByFileId: messageByFileId ?? this.messageByFileId,
      scanning: scanning ?? this.scanning,
      repairingAll: repairingAll ?? this.repairingAll,
      exportingAll: exportingAll ?? this.exportingAll,
      exportProgress: exportProgress ?? this.exportProgress,
      exportMessage: clearExportMessage ? null : (exportMessage ?? this.exportMessage),
    );
  }

  @override
  List<Object?> get props => [
        integrityByFileId,
        progressByFileId,
        messageByFileId,
        scanning,
        repairingAll,
        exportingAll,
        exportProgress,
        exportMessage,
      ];
}
