import 'package:flutter_test/flutter_test.dart';
import 'package:ai_orchestrator/core/sync/crdt/hlc.dart';

void main() {
  group('Hlc.zero', () {
    test('creates an HLC with all zero values', () {
      final h = Hlc.zero('nodeA');
      expect(h.wallMs, 0);
      expect(h.counter, 0);
      expect(h.nodeId, 'nodeA');
    });
  });

  group('Hlc.send', () {
    test('advances wallMs when wall clock is ahead', () {
      final last = Hlc(wallMs: 1000, counter: 0, nodeId: 'n1');
      final now = DateTime.fromMillisecondsSinceEpoch(2000);
      final next = Hlc.send(last, now: now);
      expect(next.wallMs, 2000);
      expect(next.counter, 0);
    });

    test('increments counter when wall clock has not advanced', () {
      final last = Hlc(wallMs: 5000, counter: 2, nodeId: 'n1');
      final now = DateTime.fromMillisecondsSinceEpoch(5000);
      final next = Hlc.send(last, now: now);
      expect(next.wallMs, 5000);
      expect(next.counter, 3);
    });

    test('uses last wallMs when wall clock goes backward', () {
      final last = Hlc(wallMs: 9000, counter: 0, nodeId: 'n1');
      final now = DateTime.fromMillisecondsSinceEpoch(8000); // past
      final next = Hlc.send(last, now: now);
      expect(next.wallMs, 9000);
      expect(next.counter, 1);
    });
  });

  group('Hlc.recv', () {
    test('takes max of all three wall components', () {
      final local = Hlc(wallMs: 3000, counter: 0, nodeId: 'n1');
      final remote = Hlc(wallMs: 5000, counter: 0, nodeId: 'n2');
      final now = DateTime.fromMillisecondsSinceEpoch(4000);
      final merged = Hlc.recv(local, remote, now: now);
      expect(merged.wallMs, 5000);
    });

    test('increments counter beyond both when wall clocks match', () {
      final local = Hlc(wallMs: 5000, counter: 3, nodeId: 'n1');
      final remote = Hlc(wallMs: 5000, counter: 7, nodeId: 'n2');
      final now = DateTime.fromMillisecondsSinceEpoch(5000);
      final merged = Hlc.recv(local, remote, now: now);
      expect(merged.wallMs, 5000);
      expect(merged.counter, 8); // remote.counter + 1
    });
  });

  group('Hlc.toString / parse', () {
    test('round-trips through toString/parse', () {
      final original = Hlc(wallMs: 1234567890123, counter: 42, nodeId: 'dev-abc');
      final parsed = Hlc.parse(original.toString());
      expect(parsed.wallMs, original.wallMs);
      expect(parsed.counter, original.counter);
      expect(parsed.nodeId, original.nodeId);
    });

    test('lexicographic order matches causal order (later wall > earlier wall)',
        () {
      final earlier = Hlc(wallMs: 1000, counter: 0, nodeId: 'n1');
      final later = Hlc(wallMs: 2000, counter: 0, nodeId: 'n1');
      expect(earlier.toString().compareTo(later.toString()), lessThan(0));
    });

    test('lexicographic order: higher counter wins when walls equal', () {
      final low = Hlc(wallMs: 1000, counter: 1, nodeId: 'n1');
      final high = Hlc(wallMs: 1000, counter: 9, nodeId: 'n1');
      expect(low.toString().compareTo(high.toString()), lessThan(0));
    });
  });

  group('Hlc comparison operators', () {
    final a = Hlc(wallMs: 1000, counter: 0, nodeId: 'x');
    final b = Hlc(wallMs: 2000, counter: 0, nodeId: 'x');

    test('> works', () => expect(b > a, isTrue));
    test('< works', () => expect(a < b, isTrue));
    test('>= works (equal)', () => expect(a >= a, isTrue));
    test('<= works (less)', () => expect(a <= b, isTrue));
    test('== works', () {
      final copy = Hlc(wallMs: 1000, counter: 0, nodeId: 'x');
      expect(a, equals(copy));
    });
  });
}
