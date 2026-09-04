import 'package:ai_orchestrator/app_factory/workshop/workshop_app_emission_package.dart';

/// Manifesto della prima applicazione prodotta dal Cantiere.
///
/// Il Manifest rappresenta l'identità e lo stato dell'artifact
/// che il Cantiere considera pronto per essere consegnato al
/// livello superiore.
///
/// È un contratto puro:
/// - non esegue build;
/// - non installa APK;
/// - non pubblica release;
/// - non accede direttamente a GitHub;
/// - non dipende dalla UI;
/// - non dipende da provider AI.
///
/// In questo modo il Manifest può diventare il contratto stabile
/// tra il motore del Cantiere e la futura UI di emissione.
final class WorkshopAppEmissionManifest {
  const WorkshopAppEmissionManifest({
    required this.id,
    required this.requestId,
    required this.target,
    required this.artifactPath,
    required this.createdAt,
    required this.status,
    this.appName,
    this.version,
    this.packageName,
    this.projectPath,
    this.message,
    this.metadata = const <String, dynamic>{},
  });

  /// Identificativo univoco del Manifest.
  final String id;

  /// Identificativo della richiesta che ha prodotto l'app.
  final String requestId;

  /// Target della build/emissione.
  final String target;

  /// Percorso dell'artifact prodotto.
  final String artifactPath;

  /// Momento in cui il Manifest è stato creato.
  final DateTime createdAt;

  /// Stato serializzato del prodotto.
  ///
  /// Viene mantenuto come String per non creare dipendenze
  /// dagli enum interni della pipeline.
  final String status;

  /// Nome leggibile dell'applicazione.
  final String? appName;

  /// Versione dell'applicazione.
  final String? version;

  /// Application/package identifier, quando disponibile.
  final String? packageName;

  /// Percorso del progetto sorgente, quando disponibile.
  final String? projectPath;

  /// Messaggio diagnostico o descrittivo.
  final String? message;

  /// Informazioni estensibili per la UI e per futuri adapter.
  final Map<String, dynamic> metadata;

  bool get hasArtifact =>
      artifactPath.trim().isNotEmpty;

  bool get hasIdentity =>
      id.trim().isNotEmpty &&
      requestId.trim().isNotEmpty;

  bool get isReady =>
      hasIdentity &&
      hasArtifact &&
      status.trim().isNotEmpty;

  /// Costruisce un Manifest direttamente da un package di emissione.
  ///
  /// Non modifica il package originale.
  factory WorkshopAppEmissionManifest.fromPackage(
    WorkshopAppEmissionPackage package, {
    String status = 'ready',
    String? packageName,
    String? projectPath,
  }) {
    return WorkshopAppEmissionManifest(
      id: package.id,
      requestId: package.requestId,
      target: package.target,
      artifactPath: package.artifactPath,
      createdAt: package.createdAt,
      status: status,
      appName: package.appName,
      version: package.version,
      packageName: packageName,
      projectPath: projectPath,
      message: package.message,
      metadata: <String, dynamic>{
        ...package.metadata,
        'emissionPackageId':
            package.id,
      },
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'requestId': requestId,
      'target': target,
      'artifactPath': artifactPath,
      'createdAt':
          createdAt.toUtc().toIso8601String(),
      'status': status,
      'appName': appName,
      'version': version,
      'packageName': packageName,
      'projectPath': projectPath,
      'message': message,
      'metadata':
          Map<String, dynamic>.unmodifiable(
        metadata,
      ),
      'hasArtifact': hasArtifact,
      'hasIdentity': hasIdentity,
      'isReady': isReady,
    };
  }

  factory WorkshopAppEmissionManifest.fromJson(
    Map<String, dynamic> json,
  ) {
    final rawCreatedAt =
        json['createdAt'];

    final parsedCreatedAt =
        rawCreatedAt is String
            ? DateTime.tryParse(
                rawCreatedAt,
              )
            : null;

    final rawMetadata =
        json['metadata'];

    final parsedMetadata =
        rawMetadata is Map
            ? Map<String, dynamic>.from(
                rawMetadata,
              )
            : const <String, dynamic>{};

    return WorkshopAppEmissionManifest(
      id: json['id'] as String? ?? '',
      requestId:
          json['requestId'] as String? ?? '',
      target:
          json['target'] as String? ?? '',
      artifactPath:
          json['artifactPath'] as String? ?? '',
      createdAt:
          parsedCreatedAt?.toUtc() ??
              DateTime.now().toUtc(),
      status:
          json['status'] as String? ?? '',
      appName:
          json['appName'] as String?,
      version:
          json['version'] as String?,
      packageName:
          json['packageName'] as String?,
      projectPath:
          json['projectPath'] as String?,
      message:
          json['message'] as String?,
      metadata: parsedMetadata,
    );
  }

  WorkshopAppEmissionManifest copyWith({
    String? id,
    String? requestId,
    String? target,
    String? artifactPath,
    DateTime? createdAt,
    String? status,
    String? appName,
    String? version,
    String? packageName,
    String? projectPath,
    String? message,
    Map<String, dynamic>? metadata,
  }) {
    return WorkshopAppEmissionManifest(
      id: id ?? this.id,
      requestId:
          requestId ?? this.requestId,
      target: target ?? this.target,
      artifactPath:
          artifactPath ?? this.artifactPath,
      createdAt:
          createdAt ?? this.createdAt,
      status:
          status ?? this.status,
      appName:
          appName ?? this.appName,
      version:
          version ?? this.version,
      packageName:
          packageName ?? this.packageName,
      projectPath:
          projectPath ?? this.projectPath,
      message:
          message ?? this.message,
      metadata:
          metadata ?? this.metadata,
    );
  }

  @override
  String toString() {
    return 'WorkshopAppEmissionManifest('
        'id: $id, '
        'requestId: $requestId, '
        'target: $target, '
        'artifactPath: $artifactPath, '
        'status: $status, '
        'appName: $appName, '
        'version: $version, '
        'isReady: $isReady'
        ')';
  }
}
