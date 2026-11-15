"""End-to-end QA of real counter ZIP and SQLite journal, without cloud."""
import hashlib
import json
import pathlib
import sqlite3
import subprocess
import sys
import tempfile
import unittest
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
RUNNER = ROOT / 'scripts/web/run_counter_journal_smoke.py'


class CounterJournalEndToEnd(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='aivexus-web-e2e-')
        self.addCleanup(self.temp.cleanup)
        self.output = pathlib.Path(self.temp.name) / 'counter'
        self.calls = 0

    def invoke(self, *args, expected=0):
        result = subprocess.run(
            [sys.executable, str(RUNNER), '--output', str(self.output), *args],
            cwd=ROOT, capture_output=True, text=True, timeout=150,
        )
        self.calls += 1
        self.assertEqual(result.returncode, expected,
                         result.stdout[-1500:] + result.stderr[-1500:])
        if expected == 0:
            return json.loads(result.stdout.strip().splitlines()[-1])
        return json.loads(result.stderr.strip().splitlines()[-1])

    def read_db(self, query, params=()):
        with sqlite3.connect(self.output / 'state.sqlite') as db:
            return db.execute(query, params).fetchall()

    def count(self, table):
        # Known internal fixture table names only, never user input.
        assert table in ('web_execution_artifact_receipts',
                         'web_execution_journal_events',
                         'web_execution_reservations')
        return self.read_db('SELECT count(*) FROM ' + table)[0][0]

    def test_real_zip_build_and_safe_replay_uses_same_bytes(self):
        result = self.invoke()
        self.assertTrue(result['ok'])
        self.assertEqual(result['status'], 'completed')
        receipt_file = self.output / 'receipt.json'
        receipt_bytes = receipt_file.read_bytes()
        receipt = json.loads(receipt_bytes)
        artifact = self.output / receipt['artifactStorageKey']
        payload = artifact.read_bytes()
        self.assertEqual(receipt['artifactSha256'],
                         hashlib.sha256(payload).hexdigest())
        self.assertEqual(receipt['artifactSizeBytes'], len(payload))
        self.assertEqual(result['artifactSha256'], receipt['artifactSha256'])
        with zipfile.ZipFile(artifact) as zf:
            self.assertIn('app.js', zf.namelist())
            self.assertIn('index.html', zf.namelist())
            self.assertIn('styles.css', zf.namelist())
        self.assertEqual(self.count('web_execution_artifact_receipts'), 1)
        self.assertEqual(self.count('web_execution_journal_events'), 3)
        self.assertEqual(self.count('web_execution_reservations'), 1)
        replayed = self.invoke('--replay')
        self.assertTrue(replayed['replayed'])
        self.assertEqual(replayed['executionId'], receipt['executionId'])
        self.assertEqual(replayed['artifactSha256'], receipt['artifactSha256'])
        self.assertEqual(receipt_file.read_bytes(), receipt_bytes)
        self.assertEqual(artifact.read_bytes(), payload)
        self.assertEqual(self.count('web_execution_artifact_receipts'), 1)
        self.assertEqual(self.count('web_execution_journal_events'), 3)
        # Without an explicit replay mode, a repeat cannot overwrite the run.
        self.assertFalse(self.invoke(expected=1)['ok'])
        self.assertEqual(receipt_file.read_bytes(), receipt_bytes)

    def test_corrupted_stored_zip_cannot_be_replayed_as_valid(self):
        self.invoke()
        receipt = json.loads((self.output / 'receipt.json').read_text())
        artifact = self.output / receipt['artifactStorageKey']
        before = artifact.read_bytes()
        artifact.write_bytes(before[:-1] + bytes([before[-1] ^ 1]))
        error = self.invoke('--replay', expected=1)
        self.assertFalse(error['ok'])
        self.assertEqual(error['status'], 'unverified')
        self.assertEqual(self.count('web_execution_artifact_receipts'), 1)
        self.assertEqual(self.count('web_execution_journal_events'), 3)

    def test_interruption_requires_explicit_reconciliation_no_retry(self):
        result = self.invoke('--inject-failure', 'interrupt')
        self.assertEqual(result['status'], 'review_required')
        self.assertEqual(self.count('web_execution_artifact_receipts'), 0)
        self.assertEqual(self.count('web_execution_journal_events'), 3)
        self.assertFalse(self.invoke('--replay', expected=1)['ok'])
        result = self.invoke('--reconcile')
        self.assertEqual(result['status'], 'failed')
        self.assertEqual(self.count('web_execution_journal_events'), 4)
        self.assertEqual(self.count('web_execution_artifact_receipts'), 0)
        self.assertFalse(self.invoke('--replay', expected=1)['ok'])
        self.assertFalse(self.invoke('--reconcile', expected=1)['ok'])

    def test_failed_tests_never_emit_artifact_receipt(self):
        result = self.invoke('--inject-failure', 'test')
        self.assertEqual(result['status'], 'failed')
        self.assertEqual(result['reason'], 'test')
        self.assertEqual(self.count('web_execution_artifact_receipts'), 0)
        self.assertFalse((self.output / 'receipt.json').exists())
        self.assertEqual(self.count('web_execution_journal_events'), 3)
        self.assertFalse(self.invoke('--replay', expected=1)['ok'])

    def test_failed_storage_does_not_claim_completion(self):
        result = self.invoke('--inject-failure', 'storage')
        self.assertEqual(result['status'], 'failed')
        self.assertEqual(result['reason'], 'storage')
        self.assertEqual(self.count('web_execution_artifact_receipts'), 0)
        self.assertFalse((self.output / 'receipt.json').exists())
        self.assertEqual(self.count('web_execution_journal_events'), 3)


if __name__ == '__main__':
    unittest.main()
