import 'package:equatable/equatable.dart';

class ModelUpdateInfo extends Equatable {
  const ModelUpdateInfo({
    required this.modelId,
    required this.currentVersion,
    this.latestVersion,
    this.updateAvailable = false,
    this.downloadUrl,
  });

  final String modelId;
  final String currentVersion;
  final String? latestVersion;
  final bool updateAvailable;
  final String? downloadUrl;

  @override
  List<Object?> get props =>
      [modelId, currentVersion, latestVersion, updateAvailable, downloadUrl];
}
