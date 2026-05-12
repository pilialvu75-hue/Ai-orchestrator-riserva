/// Hybrid Logical Clock (HLC) implementation for CRDT-based synchronization.
///
/// An HLC timestamp is a string of the form `"<wallMs>-<counter>-<nodeId>"`,
/// where:
///  - `wallMs` is the physical wall-clock millisecond (zero-padded to 16 digits)
///  - `counter` is a logical counter (zero-padded to 6 digits)
///  - `nodeId` is the local device identifier (any non-empty string)
///
/// String comparison of HLC timestamps preserves causal ordering when the
/// same node ID format is used throughout (identical nodeId strings sort
/// consistently because nodeId is the tiebreaker).
///
/// Reference: Kulkarni et al., "Logical Physical Clocks and Consistent
/// Snapshots in Globally Distributed Databases" (2014).
class Hlc implements Comparable<Hlc> {
  const Hlc({
    required this.wallMs,
    required this.counter,
    required this.nodeId,
  });

  /// Physical wall-clock component (milliseconds since epoch).
  final int wallMs;

  /// Logical counter — incremented when two events occur within the same
  /// millisecond on the same node.
  final int counter;

  /// Unique node identifier (device ID).
  final String nodeId;

  // ── Factory constructors ──────────────────────────────────────────────────

  /// Creates an HLC for a new local event, advancing the clock as needed.
  ///
  /// [lastKnown] is the node's previous HLC.  [now] is the current wall-clock
  /// time (defaults to `DateTime.now()`).
  factory Hlc.send(Hlc lastKnown, {DateTime? now}) {
    final wallNow = (now ?? DateTime.now()).millisecondsSinceEpoch;
    final wall = wallNow > lastKnown.wallMs ? wallNow : lastKnown.wallMs;
    final counter = wall == lastKnown.wallMs ? lastKnown.counter + 1 : 0;
    return Hlc(wallMs: wall, counter: counter, nodeId: lastKnown.nodeId);
  }

  /// Merges [remote] into [local] when a message is received.
  ///
  /// Returns a new HLC that causally dominates both clocks.
  factory Hlc.recv(Hlc local, Hlc remote, {DateTime? now}) {
    final wallNow = (now ?? DateTime.now()).millisecondsSinceEpoch;
    final wall =
        [wallNow, local.wallMs, remote.wallMs].reduce((a, b) => a > b ? a : b);
    final int counter;
    if (wall == local.wallMs && wall == remote.wallMs) {
      counter = local.counter > remote.counter
          ? local.counter + 1
          : remote.counter + 1;
    } else if (wall == local.wallMs) {
      counter = local.counter + 1;
    } else if (wall == remote.wallMs) {
      counter = remote.counter + 1;
    } else {
      counter = 0;
    }
    return Hlc(wallMs: wall, counter: counter, nodeId: local.nodeId);
  }

  /// Creates the initial "zero" HLC for a node.
  factory Hlc.zero(String nodeId) =>
      Hlc(wallMs: 0, counter: 0, nodeId: nodeId);

  // ── Serialisation ─────────────────────────────────────────────────────────

  /// Parses an HLC from its canonical string form.
  factory Hlc.parse(String value) {
    final parts = value.split('-');
    if (parts.length < 3) {
      throw FormatException('Invalid HLC string: $value');
    }
    // nodeId may contain dashes itself; rejoin everything after position 1.
    final wallMs = int.parse(parts[0]);
    final counter = int.parse(parts[1]);
    final nodeId = parts.sublist(2).join('-');
    return Hlc(wallMs: wallMs, counter: counter, nodeId: nodeId);
  }

  /// Serialises the HLC to its canonical string form.
  ///
  /// Zero-padding ensures correct lexicographic ordering when the string is
  /// stored in SQLite TEXT columns and sorted.
  @override
  String toString() =>
      '${wallMs.toString().padLeft(16, '0')}'
      '-${counter.toString().padLeft(6, '0')}'
      '-$nodeId';

  // ── Ordering ──────────────────────────────────────────────────────────────

  @override
  int compareTo(Hlc other) => toString().compareTo(other.toString());

  bool operator >(Hlc other) => compareTo(other) > 0;
  bool operator <(Hlc other) => compareTo(other) < 0;
  bool operator >=(Hlc other) => compareTo(other) >= 0;
  bool operator <=(Hlc other) => compareTo(other) <= 0;

  @override
  bool operator ==(Object other) =>
      other is Hlc &&
      wallMs == other.wallMs &&
      counter == other.counter &&
      nodeId == other.nodeId;

  @override
  int get hashCode => Object.hash(wallMs, counter, nodeId);
}
