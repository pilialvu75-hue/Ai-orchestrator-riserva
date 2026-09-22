import 'package:ai_orchestrator/core/memory/fabric/memory_fabric_record.dart';

final class MemoryFabricProviderDescriptor {
  MemoryFabricProviderDescriptor({
    required String providerId,
    required this.location,
    required Set<MemoryFabricPrivacyLevel> allowedPrivacy,
    this.durable = true,
  })  : providerId = _required(providerId, 'providerId'),
        allowedPrivacy = Set<MemoryFabricPrivacyLevel>.unmodifiable(
          allowedPrivacy,
        ) {
    if (!const <String>{'device', 'lan', 'cloud'}.contains(location)) {
      throw ArgumentError.value(
        location,
        'location',
        'must be device, lan or cloud',
      );
    }
  }

  final String providerId;
  final String location;
  final Set<MemoryFabricPrivacyLevel> allowedPrivacy;
  final bool durable;
}

/// Stable backend contract for local SQLite/CRDT, Supabase, NAS and future
/// additive memory nodes.
abstract interface class MemoryFabricProvider {
  MemoryFabricProviderDescriptor get descriptor;

  Future<MemoryFabricRecord> write(MemoryFabricRecord record);

  Future<MemoryFabricRecord?> read(String recordId);

  Future<List<MemoryFabricRecord>> search(MemoryFabricQuery query);

  Future<MemoryFabricSyncReport> sync();

  Future<MemoryFabricHealth> health();
}

String _required(String value, String name) {
  final normalized = value.trim();
  if (normalized.isEmpty) {
    throw ArgumentError.value(value, name, 'is required');
  }
  return normalized;
}
