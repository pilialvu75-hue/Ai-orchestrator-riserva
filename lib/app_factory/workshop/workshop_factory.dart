import 'workshop_dashboard_controller.dart';
import 'workshop_engine.dart';
import 'workshop_project_executor.dart';

/// Composition root del Cantiere.
///
/// Questo file costruisce le dipendenze principali del Workshop
/// senza inserire logica di esecuzione nella UI.
///
/// Pipeline:
///
///   DashboardController
///          ↓
///   WorkshopEngine
///          ↓
///   WorkshopProjectExecutor
///
/// Il factory non esegue produzioni automaticamente.
/// Si limita a costruire l'infrastruttura necessaria.
///
/// In questo modo la UI rimane sostituibile e il Cantiere
/// può essere utilizzato successivamente anche dall'Assistente,
/// dall'A-team e dai servizi background.
final class WorkshopFactory {
  const WorkshopFactory._();

  /// Crea un [WorkshopEngine] utilizzabile dal Cantiere.
  ///
  /// Il ProjectExecutor viene passato esplicitamente al motore.
  ///
  /// Questo è importante perché WorkshopEngine, quando deve preparare
  /// un task reale, richiede un WorkshopProjectExecutor collegato.
  static WorkshopEngine createEngine({
    WorkshopProjectExecutor? projectExecutor,
  }) {
    return WorkshopEngine(
      projectExecutor: projectExecutor,
    );
  }

  /// Crea il controller della Dashboard.
  ///
  /// Se viene fornito un [engine], il controller utilizza esattamente
  /// quell'istanza.
  ///
  /// Se non viene fornito, viene creato un engine isolato.
  ///
  /// Il secondo percorso è utile per mantenere la factory utilizzabile
  /// durante la fase incrementale di integrazione, senza introdurre
  /// automaticamente side-effect o dipendenze non richieste.
  static WorkshopDashboardController createDashboardController({
    WorkshopEngine? engine,
    WorkshopProjectExecutor? projectExecutor,
  }) {
    final resolvedEngine =
        engine ??
        createEngine(
          projectExecutor: projectExecutor,
        );

    return WorkshopDashboardController(
      engine: resolvedEngine,
    );
  }

  /// Crea l'intero blocco applicativo del Cantiere.
  ///
  /// Questa API rappresenta il punto di ingresso che potrà essere
  /// utilizzato dalla UI, dall'Assistente o successivamente dall'A-team.
  ///
  /// La costruzione rimane intenzionalmente separata dalla produzione:
  /// creare il controller NON significa avviare un progetto.
  static WorkshopDashboardController create({
    WorkshopProjectExecutor? projectExecutor,
    WorkshopEngine? engine,
  }) {
    if (engine != null) {
      return WorkshopDashboardController(
        engine: engine,
      );
    }

    final resolvedEngine = createEngine(
      projectExecutor: projectExecutor,
    );

    return WorkshopDashboardController(
      engine: resolvedEngine,
    );
  }
}
