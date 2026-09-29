import 'package:ai_orchestrator/app_factory/workshop/workshop_checkpoint_store.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_persistent_checkpoint_store.dart';
import 'package:ai_orchestrator/core/config/storage/preferences_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Opens the existing Cantiere checkpoint persistence contract on Web.
///
/// shared_preferences_web maps the already-used PreferencesService onto browser
/// local storage. W3 therefore adds a platform adapter, not a second project
/// persistence model.
abstract final class WorkshopWebCheckpointStorage {
  static Future<WorkshopCheckpointStore> open() async {
    final preferences = await SharedPreferences.getInstance();
    return PersistentWorkshopCheckpointStore(
      preferences: PreferencesService(preferences),
    );
  }
}
