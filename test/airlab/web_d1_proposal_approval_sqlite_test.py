"""Real SQLite integration for Web-owned proposal CAS and append-only audit.

Source-only tests: never connect to Cloudflare D1 or external services.
"""
import pathlib
import re
import sqlite3
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
SQL_DIR = ROOT / 'scripts/web/sql'
JS = (ROOT / 'scripts/web/d1_web_proposal_approval_writer.mjs').read_text()


def statement(name):
    m = re.search(r'const ' + name + r' = `([\s\S]*?)`;', JS)
    if not m:
        raise AssertionError('Missing SQL query: ' + name)
    return m.group(1)


class WebProposalApprovalSQLiteTest(unittest.TestCase):
    def setUp(self):
        self.db = sqlite3.connect(':memory:')
        self.db.execute('PRAGMA foreign_keys = ON')
        self.db.executescript((SQL_DIR / '001_web_approval_reservation.sql').read_text())
        self.db.executescript((SQL_DIR / '002_web_proposal_approval_audit.sql').read_text())
        self.digest = 'a' * 64
        self.db.execute("""
          INSERT INTO web_project_approvals (
            owner_subject, project_id, product, status, current_revision,
            approved_revision, approved_spec_sha256, approval_id,
            updated_at, proposal_spec_sha256
          ) VALUES (?, ?, 'aivexus-web', 'proposal_ready', 3,
                    NULL, NULL, NULL, ?, ?)
        """, ('owner', 'counter', '2026-11-14T00:00:00Z', self.digest))

    def tearDown(self):
        self.db.close()

    def approve(self, owner='owner', revision=3, digest=None,
                approval_id='web-approval-' + '1' * 36):
        return self.db.execute(statement('APPROVE_SQL'), (
            owner, 'counter', revision, digest or self.digest,
            approval_id, '2026-11-14T00:01:00Z'
        )).rowcount

    def revoke(self, owner='owner', revision=3,
               approval_id='web-approval-' + '1' * 36):
        return self.db.execute(statement('REVOKE_SQL'), (
            owner, 'counter', revision, approval_id, '2026-11-14T00:02:00Z'
        )).rowcount

    def audit(self):
        return self.db.execute("""
          SELECT event_type, revision, proposal_spec_sha256, approval_id
          FROM web_approval_audit ORDER BY event_id
        """).fetchall()

    def test_approval_is_atomic_and_creates_exactly_one_audit_row(self):
        self.assertEqual(self.approve(), 1)
        self.assertEqual(self.approve(), 0)
        row = self.db.execute("""
          SELECT status, current_revision, approved_revision,
                 approved_spec_sha256, approval_id
          FROM web_project_approvals
        """).fetchone()
        self.assertEqual(row, ('approved', 3, 3, self.digest,
                               'web-approval-' + '1' * 36))
        self.assertEqual(self.audit(), [('approved', 3, self.digest,
                                          'web-approval-' + '1' * 36)])

    def test_stale_revision_wrong_digest_and_cross_owner_are_rejected(self):
        for kwargs in [
            {'owner': 'other'},
            {'revision': 2},
            {'digest': 'b' * 64},
        ]:
            self.assertEqual(self.approve(**kwargs), 0)
        self.assertEqual(self.audit(), [])
        self.assertEqual(self.db.execute(
            "SELECT status FROM web_project_approvals"
        ).fetchone()[0], 'proposal_ready')

    def test_revocation_is_atomic_and_preserves_immutable_audit(self):
        self.assertEqual(self.approve(), 1)
        self.assertEqual(self.revoke(approval_id='web-approval-' + '2'*36), 0)
        self.assertEqual(self.revoke(revision=2), 0)
        self.assertEqual(self.revoke(), 1)
        self.assertEqual(self.revoke(), 0)
        self.assertEqual(self.db.execute("""
          SELECT status,approved_revision,approved_spec_sha256,approval_id
          FROM web_project_approvals
        """).fetchone(), ('revoked', None, None, None))
        self.assertEqual([x[0] for x in self.audit()], ['approved', 'revoked'])
        self.assertEqual(self.audit()[1][-1], 'web-approval-' + '1'*36)
        self.assertEqual(self.approve(), 0)

    def test_direct_approval_with_untrusted_hash_aborts(self):
        with self.assertRaises(sqlite3.IntegrityError):
            self.db.execute("""
              UPDATE web_project_approvals
              SET status='approved', approved_revision=3,
                  approved_spec_sha256=?, approval_id='forged'
              WHERE project_id='counter'
            """, ('b' * 64,))
        self.assertEqual(self.audit(), [])

    def test_direct_approved_insert_without_proposal_is_rejected(self):
        with self.assertRaises(sqlite3.IntegrityError):
            self.db.execute("""
              INSERT INTO web_project_approvals (
                owner_subject,project_id,product,status,current_revision,
                approved_revision,approved_spec_sha256,approval_id,updated_at
              ) VALUES ('owner','second','aivexus-web','approved',1,
                        1,?, 'forged','2026-11-14T00:00:00Z')
            """, ('a' * 64,))
        self.assertEqual(self.db.execute(
            "SELECT count(*) FROM web_project_approvals"
        ).fetchone()[0], 1)

    def test_audit_cannot_be_rewritten_or_deleted(self):
        self.approve()
        with self.assertRaises(sqlite3.IntegrityError):
            self.db.execute("UPDATE web_approval_audit SET event_type='revoked'")
        with self.assertRaises(sqlite3.IntegrityError):
            self.db.execute('DELETE FROM web_approval_audit')
        self.assertEqual(len(self.audit()), 1)

    def test_approved_digest_revision_and_identity_cannot_be_silently_changed(self):
        self.assertEqual(self.approve(), 1)
        for sql, param in [
            ("UPDATE web_project_approvals SET proposal_spec_sha256=?",
             'b' * 64),
            ("UPDATE web_project_approvals SET current_revision=?", 4),
            ("UPDATE web_project_approvals SET approval_id=?", 'forged'),
            ("UPDATE web_project_approvals SET status=?", 'draft'),
        ]:
            with self.assertRaises(sqlite3.IntegrityError):
                self.db.execute(sql, (param,))
        self.assertEqual(len(self.audit()), 1)
        self.assertEqual(self.revoke(), 1)
        self.assertEqual([event[0] for event in self.audit()],
                         ['approved', 'revoked'])

    def test_migration_requires_valid_lowercase_sha256_for_proposals(self):
        with self.assertRaises(sqlite3.IntegrityError):
            self.db.execute("""
              UPDATE web_project_approvals SET proposal_spec_sha256=?
              WHERE project_id='counter'
            """, ('A' * 64,))
        self.assertEqual(self.approve(), 1)


if __name__ == '__main__':
    unittest.main()
