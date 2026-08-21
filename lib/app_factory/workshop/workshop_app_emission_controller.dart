import 'workshop_build_lab.dart';

/// Punto di emissione del Cantiere.
///
/// Separa la build dalla decisione di rendere disponibile l'artifact.
/// Non installa APK e non pubblica autonomamente su servizi esterni:
/// produce solamente una decisione immutabile che la UI o il livello
/// superiore può utilizzare per il passo successivo.
final class WorkshopAppEmissionDecision {
  const WorkshopAppEmissionDecision({
    required this.requestId,
    required this.target,
    required this.emittable,
    this.artifactPath,
    this.message,
    this.errors = const <String>[],
  });

  final String requestId;
  final WorkshopBuildTarget target;
  final bool emittable;
  final String? artifactPath;
  final String? message;
  final List<String> errors;

  bool get hasArtifact =>
      artifactPath != null && artifactPath!.trim().isNotEmpty;
}

/// Controller che trasforma un risultato di build in una decisione
/// di emissione sicura.
///
/// Questo anello non modifica il progetto e non bypassa il Build Lab.
final class WorkshopAppEmissionController {
  const WorkshopAppEmissionController();

  WorkshopAppEmissionDecision evaluate(
    WorkshopBuildResult result,
  ) {
    if (!result.succeeded) {
      return WorkshopAppEmissionDecision(
        requestId: result.requestId,
        target: result.target,
        emittable: false,
        artifactPath: result.artifactPath,
        message:
            result.message ?? 'Build did not succeed.',
        errors: result.errors.isEmpty
            ? const <String>['build_not_succeeded']
            : result.errors,
      );
    }

    if (!result.hasArtifact) {
      return WorkshopAppEmissionDecision(
        requestId: result.requestId,
        target: result.target,
        emittable: false,
        message:
            'Build succeeded but no artifact was detected.',
        errors: const <String>[
          'build_artifact_not_detected',
        ],
      );
    }

    return WorkshopAppEmissionDecision(
      requestId: result.requestId,
      target: result.target,
      emittable: true,
      artifactPath: result.artifactPath,
      message:
          result.message ?? 'Artifact is ready for emission.',
    );
  }

  Map<String, dynamic> diagnostics(
    WorkshopBuildResult result,
  ) {
    final decision = evaluate(result);

    return <String, dynamic>{
      'requestId': result.requestId,
      'target': result.target.name,
      'buildStatus': result.status.name,
      'emittable': decision.emittable,
      'hasArtifact': decision.hasArtifact,
      'artifactPath': decision.artifactPath,
      'testsPassed': result.testsPassed,
      'analysisPassed': result.analysisPassed,
      'formatPassed': result.formatPassed,
      'errors': decision.errors,
    };
  }
}
