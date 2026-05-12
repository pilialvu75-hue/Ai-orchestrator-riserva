import 'package:ai_orchestrator/core/plugins/plugin.dart';
import 'package:ai_orchestrator/features/document_intelligence/data/services/local_document_index_service.dart';

class OfflineDocumentIntelligencePlugin implements Plugin {
  OfflineDocumentIntelligencePlugin({
    required LocalDocumentIndexService indexService,
  }) : _indexService = indexService;

  static const String pluginId = 'offline_document_intelligence';

  final LocalDocumentIndexService _indexService;

  @override
  String get id => pluginId;

  @override
  String get displayName => 'Offline Document Intelligence';

  @override
  String get version => '1.0.0';

  @override
  Future<void> initialize() async {}

  @override
  Future<void> dispose() async {}

  Future<int> indexDocument({
    required String filePath,
    String? documentId,
  }) {
    return _indexService.indexDocument(
      filePath: filePath,
      documentId: documentId,
    );
  }

  Future<List<LocalDocumentMatch>> search(
    String query, {
    int limit = 6,
  }) {
    return _indexService.search(query, limit: limit);
  }
}
