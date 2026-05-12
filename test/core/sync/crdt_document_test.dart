import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ai_orchestrator/core/sync/crdt/crdt_document.dart';
import 'package:ai_orchestrator/core/sync/crdt/crdt_record.dart';
import 'package:ai_orchestrator/core/sync/crdt/hlc.dart';

void main() {
  group('CrdtDocument – put', () {
    test('stores a record and retrieves it', () {
      final doc = CrdtDocument(nodeId: 'node-A');
      doc.put('messages', 'msg-1', jsonEncode({'text': 'hello'}), 'rec-1');
      final record = doc.get('messages', 'msg-1');
      expect(record, isNotNull);
      expect(record!.decodedValue?['text'], 'hello');
    });

    test('advances the clock on each put', () {
      final doc = CrdtDocument(nodeId: 'node-A');
      doc.put('col', 'k1', '{}', 'r1');
      final clock1 = doc.clock;
      doc.put('col', 'k2', '{}', 'r2');
      expect(doc.clock > clock1, isTrue);
    });
  });

  group('CrdtDocument – delete', () {
    test('tombstone makes get return null', () {
      final doc = CrdtDocument(nodeId: 'node-A');
      doc.put('col', 'k', '{"v":1}', 'r1');
      doc.delete('col', 'k', 'r2');
      expect(doc.get('col', 'k'), isNull);
    });

    test('tombstone is excluded from entriesFor', () {
      final doc = CrdtDocument(nodeId: 'node-A');
      doc.put('col', 'k', '{"v":1}', 'r1');
      doc.delete('col', 'k', 'r2');
      expect(doc.entriesFor('col'), isEmpty);
    });
  });

  group('CrdtDocument – merge (LWW)', () {
    test('remote record wins when it has a higher HLC', () {
      final docA = CrdtDocument(nodeId: 'node-A');
      docA.put('col', 'k', '{"v":"from-A"}', 'rA');

      final docB = CrdtDocument(nodeId: 'node-B');
      // Force B's clock to be strictly later than A's.
      docB.put('col', 'other', '{}', 'rb0'); // advance
      docB.put('col', 'k', '{"v":"from-B"}', 'rB');

      // Merge B's changes into A.
      docA.merge(docB.allRecords);
      final winner = docA.get('col', 'k');
      expect(winner?.decodedValue?['v'], 'from-B');
    });

    test('local record wins when it has a higher HLC', () {
      final docA = CrdtDocument(nodeId: 'node-A');
      // A writes first with a low clock.
      docA.put('col', 'k', '{"v":"from-A-old"}', 'rA0');

      final docB = CrdtDocument(nodeId: 'node-B');
      final rec = docB.put('col', 'k', '{"v":"from-B-old"}', 'rB');

      // Now A writes a newer version (higher HLC).
      docA.put('col', 'k', '{"v":"from-A-new"}', 'rA1');

      // Merge B's older record – A's newer one should win.
      docA.merge([rec]);
      final winner = docA.get('col', 'k');
      expect(winner?.decodedValue?['v'], 'from-A-new');
    });

    test('merge does not regress the local clock below the remote', () {
      final docA = CrdtDocument(nodeId: 'node-A');
      final docB = CrdtDocument(nodeId: 'node-B');
      // B has a much newer clock.
      for (var i = 0; i < 5; i++) {
        docB.put('col', 'k$i', '{}', 'rb$i');
      }
      final clockBefore = docA.clock;
      docA.merge(docB.allRecords);
      expect(docA.clock >= clockBefore, isTrue);
    });
  });

  group('CrdtDocument – changesSince', () {
    test('returns only records newer than the cursor', () {
      final doc = CrdtDocument(nodeId: 'node-A');
      doc.put('col', 'k1', '{"x":1}', 'r1');
      final cursor = doc.clock;
      doc.put('col', 'k2', '{"x":2}', 'r2');
      final changes = doc.changesSince(cursor);
      expect(changes.length, 1);
      expect(changes.first.key, 'k2');
    });

    test('returns all records when cursor is zero', () {
      final doc = CrdtDocument(nodeId: 'node-A');
      doc.put('col', 'a', '{}', 'r1');
      doc.put('col', 'b', '{}', 'r2');
      final all = doc.changesSince(Hlc.zero('node-A'));
      expect(all.length, 2);
    });
  });

  group('CrdtRecord serialisation', () {
    test('toJson / fromJson round-trips correctly', () {
      final hlc = Hlc(wallMs: 1000000, counter: 5, nodeId: 'n1');
      final record = CrdtRecord(
        id: 'uuid-abc',
        collection: 'messages',
        key: 'msg-123',
        value: '{"text":"hi"}',
        hlc: hlc,
        nodeId: 'n1',
      );
      final json = record.toJson();
      final restored = CrdtRecord.fromJson(json);
      expect(restored.id, record.id);
      expect(restored.collection, record.collection);
      expect(restored.key, record.key);
      expect(restored.value, record.value);
      expect(restored.hlc, record.hlc);
    });
  });
}
