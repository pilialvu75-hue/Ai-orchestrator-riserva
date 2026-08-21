/// Pacchetto immutabile prodotto quando il Cantiere ha un artifact
/// pronto per essere consegnato al livello superiore.
///
/// Questo contratto non esegue build, non installa APK e non pubblica
/// nulla. Rappresenta esclusivamente ciò che il Cantiere è riuscito
/// a produrre e che può quindi essere mostrato dalla UI o passato
/// al successivo anello di emissione.
///
/// Il contratto resta indipendente da:
/// - Flutter UI;
/// - GitHub;
/// - provider AI;
/// - installer Android;
/// - sistemi cloud.
///
/// In questo modo il Cantiere può produrre lo stesso tipo di
/// pacchetto sia in Local sia in Hybrid/Cloud.
final class WorkshopAppEmissionPackage {
  const WorkshopAppEmissionPackage({
    required this.id,
    required this.requestId,
    required this.target,
    required this.artifactPath,
    required this.createdAt,
    this.appName,
    this.version,
    this.message,
    this.metadata = const <String, dynamic>{},
  });

  final String id;
  final String requestId;

  /// Target della build, mantenuto come String per evitare che
  /// questo contratto dipenda dagli enum del Build Lab.
  final String target;

  /// Percorso locale dell'artifact prodotto.
  final String artifactPath;

  final DateTime createdAt;

  final String? appName;
  final String? version;
  final String? message;

  final Map<String, dynamic> metadata;

  bool get hasArtifact =>
      artifactPath.trim().isNotEmpty;

  bool get isReady =>
      hasArtifact &&
      requestId.trim().isNotEmpty;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'requestId': requestId,
      'target': target,
      'artifactPath': artifactPath,
      'createdAt': createdAt.toUtc().toIso8601String(),
      'appName': appName,
      'version': version,
      'message': message,
      'metadata':
          Map<String, dynamic>.unmodifiable(
        metadata,
      ),
      'hasArtifact': hasArtifact,
      'isReady': isReady,
    };
  }

  factory WorkshopAppEmissionPackage.fromJson(
    Map<String, dynamic> json,
  ) {
    final createdAtValue =
        json['createdAt'];

    DateTime createdAt;

    if (createdAtValue is String) {
      createdAt =
          DateTime.tryParse(
                createdAtValue,
              )?.toUtc() ??
              DateTime.now().toUtc();
    } else {
      createdAt =
          DateTime.now().toUtc();
    }

    final rawMetadata =
        json['metadata'];

    final metadata =
        rawMetadata is Map
            ? Map<String, dynamic>.from(
                rawMetadata,
              )
            : const <String, dynamic>{};

    return WorkshopAppEmissionPackage(
      id: json['id'] as String? ?? '',
      requestId:
          json['requestId'] as String? ?? '',
      target:
          json['target'] as String? ?? '',
      artifactPath:
          json['artifactPath'] as String? ?? '',
      createdAt: createdAt,
      appName:
          json['appName'] as String?,
      version:
          json['version'] as String?,
      message:
          json['message'] as String?,
      metadata: metadata,
    );
  }

  WorkshopAppEmissionPackage copyWith({
    String? id,
    String? requestId,
    String? target,
    String? artifactPath,
    DateTime? createdAt,
    String? appName,
    String? version,
    String? message,
    Map<String, dynamic>? metadata,
  }) {
    return WorkshopAppEmissionPackage(
      id: id ?? this.id,
      requestId:
          requestId ?? this.requestId,
      target: target ?? this.target,
      artifactPath:
          artifactPath ?? this.artifactPath,
      createdAt:
          createdAt ?? this.createdAt,
      appName:
          appName ?? this.appName,
      version:
          version ?? this.version,
      message:
          message ?? this.message,
      metadata:
          metadata ?? this.metadata,
    );
  }

  @override
  String toString() {
    return 'WorkshopAppEmissionPackage('
        'id: $id, '
        'requestId: $requestId, '
        'target: $target, '
        'artifactPath: $artifactPath, '
        'appName: $appName, '
        'version: $version, '
        'isReady: $isReady'
        ')';
  }
}
