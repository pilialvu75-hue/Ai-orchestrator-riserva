/// Local-first CRDT synchronization module.
///
/// Provides a conflict-free, offline-first data layer backed by Hybrid
/// Logical Clocks (HLC) and Last-Write-Wins (LWW) maps — inspired by the
/// Automerge CRDT design.
///
/// Key classes:
/// * [Hlc] – Hybrid Logical Clock for causal ordering.
/// * [CrdtRecord] – Single change record in the CRDT log.
/// * [CrdtDocument] – In-memory LWW document store.
/// * [SyncManager] – Coordinates CRDT state with SQLite persistence.
/// * [LocalSyncServer] – Exposes sync HTTP endpoints on the LAN.
/// * [LocalSyncClient] – Exchanges changesets with a peer.
/// * [SyncDiscoveryService] – Discovers peers via UDP broadcast.
/// * [SyncPeer] – Represents a discovered peer device.
library;

export 'crdt/hlc.dart';
export 'crdt/crdt_record.dart';
export 'crdt/crdt_document.dart';
export 'sync_manager.dart';
export 'network/sync_peer.dart';
export 'network/sync_protocol.dart';
export 'network/local_sync_server.dart';
export 'network/local_sync_client.dart';
export 'network/sync_discovery_service.dart';
