"""Real SQLite contract tests for Web-only D1 journal SQL. No cloud costs."""
import pathlib
import re
import sqlite3
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
DIR = ROOT / 'scripts/web/sql'
JS = (ROOT / 'scripts/web/d1_execution_journal_store.mjs').read_text()
RESERVATION = (ROOT / 'scripts/web/d1_approval_reservation_store.mjs').read_text()
KEY = 'a' * 64
ATTEMPT = '11111111-1111-4111-8111-111111111111'
TOKEN = '22222222-2222-4222-8222-222222222222'
WRONG = '33333333-3333-4333-8333-333333333333'
SPEC = 'b' * 64
ZIP = 'c' * 64
TIMES = ['2026-11-15T10:00:00.000Z', '2026-11-15T10:00:00.001Z',
         '2026-11-15T10:00:00.002Z', '2026-11-15T10:00:00.003Z']


def sql(name, source=JS):
    found = re.search(r'const ' + name + r' = `([\s\S]*?)`;', source)
    if not found:
        raise AssertionError('Missing D1 SQL: ' + name)
    return found.group(1)


class WebJournalSQLite(unittest.TestCase):
    def setUp(self):
        self.db = sqlite3.connect(':memory:')
        self.db.execute('PRAGMA foreign_keys = ON')
        for migration in ('001_web_approval_reservation.sql',
                          '002_web_proposal_approval_audit.sql',
                          '003_web_execution_journal.sql'):
            self.db.executescript((DIR / migration).read_text())
        self.db.execute("""
          INSERT INTO web_project_approvals
          (owner_subject,project_id,product,status,current_revision,
           approved_revision,approved_spec_sha256,approval_id,updated_at,
           proposal_spec_sha256)
          VALUES ('owner','counter','aivexus-web','approved',1,1,?,
                  'approval-1',?,?)
        """, (SPEC, TIMES[0], SPEC))
        self.db.execute(sql('INSERT_RESERVATION', RESERVATION), (
            KEY, 'owner', 'counter', 1, SPEC,
            'web-exec-1', ATTEMPT, TIMES[0], 'approval-1'))

    def tearDown(self):
        self.db.close()

    def run_sql(self, name, *args):
        return self.db.execute(sql(name), args).rowcount

    def state(self):
        return self.db.execute(
            "SELECT status FROM web_execution_reservations"
        ).fetchone()[0]

    def events(self):
        return self.db.execute("""
          SELECT journal_version,from_status,to_status
          FROM web_execution_journal_events ORDER BY event_id
        """).fetchall()

    def receipts(self):
        return self.db.execute("""
          SELECT artifact_sha256,artifact_storage_key,artifact_size_bytes
          FROM web_execution_artifact_receipts
        """).fetchall()

    def claim(self, token=TOKEN):
        return self.run_sql('CLAIM_SQL', KEY, ATTEMPT, token, TIMES[1])

    def complete(self, token=TOKEN):
        return self.run_sql('COMPLETE_SQL', KEY, ATTEMPT, token,
                            ZIP, 1024, TIMES[2])

    def revoke(self):
        return self.db.execute("""
          UPDATE web_project_approvals SET status='revoked',
          approved_revision=NULL,approved_spec_sha256=NULL,
          approval_id=NULL,updated_at=?
          WHERE owner_subject='owner' AND project_id='counter'
        """, (TIMES[1],)).rowcount

    def test_reservation_initial_event_and_single_claim(self):
        self.assertEqual(self.events(), [(0, None, 'reserved')])
        self.assertEqual(sum(self.claim() for _ in range(20)), 1)
        self.assertEqual(self.events(), [
            (0, None, 'reserved'), (1, 'reserved', 'running')])
        self.assertEqual(self.claim(WRONG), 0)
        self.assertEqual(self.receipts(), [])

    def test_completed_zip_receipt_is_atomic_and_unique(self):
        self.assertEqual(self.claim(), 1)
        self.assertEqual(self.complete(WRONG), 0)
        self.assertEqual(self.complete(), 1)
        self.assertEqual(self.complete(), 0)
        self.assertEqual(self.state(), 'completed')
        self.assertEqual(self.events()[-1], (2, 'running', 'completed'))
        self.assertEqual(self.receipts(), [
            (ZIP, 'web-artifacts/web-exec-1/' + ZIP + '.zip', 1024)])
        row = self.db.execute(sql('READ_RECEIPT_SQL'), (KEY,)).fetchone()
        self.assertEqual(row[0], 'web-exec-1')
        self.assertEqual(row[3], ZIP)

    def test_revocation_blocks_new_claims(self):
        self.assertEqual(self.revoke(), 1)
        self.assertEqual(self.claim(), 0)
        self.assertEqual(self.state(), 'reserved')
        self.assertEqual(self.events(), [(0, None, 'reserved')])

    def test_revocation_after_claim_blocks_completion(self):
        self.assertEqual(self.claim(), 1)
        self.assertEqual(self.revoke(), 1)
        self.assertEqual(self.complete(), 0)
        self.assertEqual(self.receipts(), [])
        self.assertEqual(self.run_sql('FLAG_INTERRUPTED_SQL',
                                      KEY, ATTEMPT, TOKEN, TIMES[2]), 1)
        self.assertEqual(self.state(), 'review_required')

    def test_interrupted_attempt_cannot_retry_or_complete(self):
        self.claim()
        self.assertEqual(self.run_sql('FLAG_INTERRUPTED_SQL',
                                      KEY, ATTEMPT, TOKEN, TIMES[2]), 1)
        self.assertEqual(self.claim(), 0)
        self.assertEqual(self.complete(), 0)
        self.assertEqual(self.run_sql('FAIL_SQL', KEY, ATTEMPT, TOKEN,
                                      'reconciliation', TIMES[3]), 1)
        self.assertEqual(self.state(), 'failed')
        self.assertEqual(self.events()[-2:], [
            (2, 'running', 'review_required'),
            (3, 'review_required', 'failed')])
        self.assertEqual(self.receipts(), [])

    def test_failed_test_and_failed_preflight_never_make_receipts(self):
        self.claim()
        self.assertEqual(self.run_sql('FAIL_SQL', KEY, ATTEMPT, TOKEN,
                                      'test', TIMES[2]), 1)
        self.assertEqual(self.complete(), 0)
        self.assertEqual(self.receipts(), [])
        self.assertEqual(self.state(), 'failed')

    def test_failure_preflight_has_no_worker_or_artifact(self):
        self.assertEqual(self.run_sql('FAIL_PREFLIGHT_SQL',
                                      KEY, ATTEMPT, TIMES[1]), 1)
        self.assertEqual(self.claim(), 0)
        self.assertEqual(self.state(), 'failed')
        self.assertEqual(self.events()[-1], (1, 'reserved', 'failed'))

    def test_direct_status_revision_and_attempt_tampering_aborts(self):
        for query in (
            "UPDATE web_execution_reservations SET status='completed'",
            "UPDATE web_execution_reservations SET status='running'",
            "UPDATE web_execution_reservations SET attempt_id='forged'",
            "UPDATE web_execution_reservations SET journal_version=25",
            "UPDATE web_execution_reservations SET artifact_sha256='" + ZIP + "'",
        ):
            with self.assertRaises(sqlite3.IntegrityError):
                self.db.execute(query)
        self.assertEqual(self.state(), 'reserved')

    def test_forged_events_and_unverified_receipt_cannot_be_inserted(self):
        with self.assertRaises(sqlite3.IntegrityError):
            self.db.execute("""
              INSERT INTO web_execution_journal_events
              (idempotency_key,execution_id,attempt_id,journal_version,
               from_status,to_status,event_at)
              VALUES (?,?,?,?,?,?,?)
            """, (KEY, 'web-exec-1', ATTEMPT, 25, 'reserved',
                  'completed', TIMES[1]))
        with self.assertRaises(sqlite3.IntegrityError):
            self.db.execute("""
              INSERT INTO web_execution_artifact_receipts
              (idempotency_key,execution_id,attempt_id,approved_spec_sha256,
               artifact_sha256,artifact_storage_key,artifact_size_bytes,
               recorded_at) VALUES (?,?,?,?,?,?,?,?)
            """, (KEY, 'web-exec-1', ATTEMPT, SPEC, ZIP,
                  'web-artifacts/web-exec-1/' + ZIP + '.zip', 1024, TIMES[2]))
        self.assertEqual(self.receipts(), [])

    def test_history_is_immutable(self):
        self.claim()
        self.complete()
        for query in (
            'DELETE FROM web_execution_reservations',
            'DELETE FROM web_execution_journal_events',
            "UPDATE web_execution_journal_events SET to_status='failed'",
            'DELETE FROM web_execution_artifact_receipts',
            'UPDATE web_execution_artifact_receipts SET artifact_size_bytes=1',
        ):
            with self.assertRaises(sqlite3.IntegrityError):
                self.db.execute(query)
        self.assertEqual(len(self.events()), 3)
        self.assertEqual(len(self.receipts()), 1)

    def test_existing_reservation_insert_still_works_after_migration(self):
        self.db.execute(sql('INSERT_RESERVATION', RESERVATION), (
            'd' * 64, 'owner', 'counter', 1, SPEC,
            'web-exec-2', '44444444-4444-4444-8444-444444444444',
            TIMES[3], 'approval-1'))
        self.assertEqual(self.db.execute(
            'SELECT count(*) FROM web_execution_reservations'
        ).fetchone()[0], 2)
        self.assertEqual(self.db.execute(
            'SELECT count(*) FROM web_execution_journal_events'
        ).fetchone()[0], 2)


if __name__ == '__main__':
    unittest.main()
