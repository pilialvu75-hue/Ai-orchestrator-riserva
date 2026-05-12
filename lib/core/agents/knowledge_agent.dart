import 'package:ai_orchestrator/core/agents/base_agent.dart';
import 'package:ai_orchestrator/core/agents/shared_context.dart';

/// Abstract contract for the knowledge agent role.
///
/// The [KnowledgeAgent] is the **retrieval, search, and verification
/// specialist** of the multi-agent system.  Its responsibilities are:
///
/// - Retrieve relevant facts from a knowledge source (local DB, vector store,
///   or external API).
/// - Search across multiple sources and rank results by relevance.
/// - Verify claims by cross-checking against stored knowledge.
/// - Store new knowledge acquired during a session.
///
/// Concrete implementations will wrap vector databases, document retrievers,
/// or structured knowledge graphs.  No real retrieval logic is implemented
/// here — this is a pure architectural contract.
///
/// Dependency rule:
///   core/agents/ ← features/ knowledge implementations
///   core/agents/ → core/ only (no native/ or features/ imports here)
abstract class KnowledgeAgent extends BaseAgent {
  /// Retrieves knowledge entries relevant to [query] from this agent's
  /// knowledge source.
  ///
  /// [maxResults] caps the number of entries returned (default: 5).
  Future<KnowledgeResult> retrieve(
    String query,
    SharedContext context, {
    int maxResults = 5,
  });

  /// Verifies whether [claim] is supported by the agent's knowledge source.
  ///
  /// Returns a [VerificationResult] with a confidence score and supporting
  /// evidence.
  Future<VerificationResult> verify(String claim, SharedContext context);

  /// Stores [entry] in the agent's knowledge source for future retrieval.
  Future<void> store(KnowledgeEntry entry);

  /// Identifier of the underlying knowledge source (e.g. `'sqlite_vector'`,
  /// `'pinecone'`, `'in_memory'`).
  String get sourceId;

  // TODO(future): add summarise(List<KnowledgeEntry>) → String for RAG pipeline.
  // TODO(future): add Stream<KnowledgeEntry> streamRelevant(String query).
}

/// A single item in a knowledge store.
class KnowledgeEntry {
  const KnowledgeEntry({
    required this.id,
    required this.content,
    this.source,
    this.tags = const [],
    this.metadata = const {},
  });

  /// Unique identifier for this entry.
  final String id;

  /// Textual content of the knowledge entry.
  final String content;

  /// Optional origin label (e.g. URL, document title, agent ID).
  final String? source;

  /// Semantic tags for category-based filtering.
  final List<String> tags;

  /// Arbitrary JSON-serialisable metadata.
  final Map<String, dynamic> metadata;

  @override
  String toString() =>
      'KnowledgeEntry(id: $id, tags: $tags, source: ${source ?? '-'})';
}

/// Retrieval result returned by [KnowledgeAgent.retrieve].
class KnowledgeResult {
  const KnowledgeResult({
    required this.query,
    required this.entries,
    this.success = true,
    this.error,
  });

  final String query;
  final List<KnowledgeEntry> entries;
  final bool success;
  final String? error;

  @override
  String toString() =>
      'KnowledgeResult(query: "$query", entries: ${entries.length})';
}

/// Verification result returned by [KnowledgeAgent.verify].
class VerificationResult {
  const VerificationResult({
    required this.claim,
    required this.isSupported,
    this.confidence = 0.0,
    this.evidence = const [],
    this.success = true,
    this.error,
  });

  /// The claim that was evaluated.
  final String claim;

  /// Whether the knowledge source supports this claim.
  final bool isSupported;

  /// Confidence score in the range [0.0, 1.0].
  final double confidence;

  /// Knowledge entries that serve as evidence for or against the claim.
  final List<KnowledgeEntry> evidence;

  final bool success;
  final String? error;

  @override
  String toString() =>
      'VerificationResult(isSupported: $isSupported, '
      'confidence: $confidence)';
}
