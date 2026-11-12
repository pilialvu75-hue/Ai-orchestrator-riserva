"""SQLite integration tests for exact D1 SQL. No Cloudflare binding or fees."""
import pathlib
import re
import sqlite3
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
JS = (ROOT / 'scripts/web/d1_approval_reservation_store.mjs').read_text()
SCHEMA = (ROOT / 'scripts/web/sql/001_web_approval_reservation.sql').read_text()

def statement(name):
    tick = chr(96)
    match = re.search(r'const ' + name + r' = ' + tick + r'([^' + tick + r']+)' + tick + r';', JS)
    if not match:
        raise AssertionError('Missing D1 SQL: ' + name)
    return match.group(1)

class WebApprovalD1Tests(unittest.TestCase):
    def setUp(self):
        self.db = sqlite3.connect(':memory:')
        self.db.execute('PRAGMA foreign_keys = ON')
        self.db.executescript(SCHEMA)
        self.db.execute("""
          INSERT INTO web_project_approvals
          (owner_subject,project_id,product,status,current_revision,
           approved_revision,approved_spec_sha256,approval_id,updated_at)
          VALUES (?,?,?,?,?,?,?,?,?)
        """, ('owner', 'counter', 'aivexus-web', 'approved', 1, 1,
              'a' * 64, 'approval-1', '2026-11-12T00:00:00Z'))

    def tearDown(self):
        self.db.close()

    def reserve(self, key='key-1', revision=1, digest=None,
                approval='approval-1', attempt='attempt-1'):
        return self.db.execute(statement('INSERT_RESERVATION'), (
            key, 'owner', 'counter', revision, digest or 'a' * 64,
            'exec-' + key, attempt, '2026-11-12T00:00:00Z', approval
        )).rowcount

    def test_sqlite_atomic_insert_and_duplicate_are_consistent(self):
        self.assertEqual(self.reserve(), 1)
        self.assertEqual(self.reserve(key='key-1', attempt='attempt-2'), 0)
        rows = self.db.execute('SELECT * FROM web_execution_reservations').fetchall()
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0][8], 'attempt-1')
        self.assertEqual(rows[0][9], 'reserved')
        self.assertIsNone(rows[0][10])

    def test_revocation_prevents_insert_after_stale_read(self):
        row = self.db.execute(statement('READ_APPROVAL'), ('owner', 'counter')).fetchone()
        self.assertIsNotNone(row)
        self.db.execute("UPDATE web_project_approvals SET status='revoked' WHERE owner_subject='owner' AND project_id='counter'")
        self.assertEqual(self.reserve(), 0)
        self.assertEqual(self.db.execute('SELECT count(*) FROM web_execution_reservations').fetchone()[0], 0)

    def test_revision_change_requires_new_approval_and_keeps_old_receipt(self):
        self.assertEqual(self.reserve(), 1)
        self.db.execute("""
          UPDATE web_project_approvals
          SET current_revision=2,approved_revision=2,
              approved_spec_sha256=?,approval_id='approval-2'
          WHERE owner_subject='owner' AND project_id='counter'
        """, ('b' * 64,))
        self.assertEqual(self.reserve(key='key-2', revision=1), 0)
        self.assertEqual(self.reserve(key='key-2', revision=2,
                                      digest='b' * 64, approval='approval-2',
                                      attempt='attempt-2'), 1)
        self.assertEqual(self.db.execute('SELECT count(*) FROM web_execution_reservations').fetchone()[0], 2)

    def test_mismatched_approval_fails(self):
        self.assertEqual(self.reserve(approval='browser-forged'), 0)

if __name__ == '__main__':
    unittest.main()
