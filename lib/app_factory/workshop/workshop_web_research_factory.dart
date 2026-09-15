import 'package:get_it/get_it.dart';
import 'package:http/http.dart' as http;

import 'package:ai_orchestrator/app_factory/workshop/workshop_inference_service_factory.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_web_research_service.dart';

/// Composition helper for the optional Cantiere Web-research capability.
///
/// The UI does not need to know which provider performs research. Production
/// obtains the already registered HTTP client and builds the Workshop-owned
/// ranked-search stack; reduced test containers without HTTP remain valid and
/// simply operate offline/local.
abstract final class WorkshopWebResearchFactory {
  static WorkshopWebResearchService? create({GetIt? locator}) {
    final sl = locator ?? GetIt.instance;
    if (!sl.isRegistered<http.Client>()) return null;

    return WorkshopWebResearchService(
      webSearchTool: WorkshopInferenceServiceFactory.createWorkshopWebSearchTool(
        client: sl<http.Client>(),
      ),
    );
  }
}
