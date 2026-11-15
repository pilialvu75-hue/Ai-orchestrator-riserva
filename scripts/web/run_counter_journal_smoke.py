#!/usr/bin/env python3
"""Aivexus Web isolated end-to-end counter build with real SQLite journal.

Synthetic, trusted test approval only. No Access login, production API, D1
binding, external object store, AI model, payments, or deployment.
Never mistake the local object-store directory for production artifact hosting.
"""
import argparse
import hashlib
import json
import pathlib
import re
import sqlite3
import subprocess
import sys
import uuid
import zipfile

from build_counter_smoke import build as generate_counter

ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / 'scripts/web'
SQL_DIR = SCRIPTS / 'sql'
JOURNAL_JS = (SCRIPTS / 'd1_execution_journal_store.mjs').read_text()
RESERVE_JS = (SCRIPTS / 'd1_approval_reservation_store.mjs').read_text()

OWNER = 'synthetic-web-test-owner'
PROJECT = 'counter-lab'
SPEC = hashlib.sha256(b'original-counter-specification-v1').hexdigest()
APPROVAL = 'synthetic-approval-revision-1'
IDEMPOTENCY = hashlib.sha256(json.dumps(
    ['aivexus-web-execution-v1', OWNER, PROJECT, 1, SPEC],
    separators=(',', ':')).encode('utf-8')).hexdigest()
EXECUTION = 'web-exec-' + IDEMPOTENCY[:32]
ATTEMPT = str(uuid.uuid5(uuid.NAMESPACE_URL, 'aivexus-attempt-' + IDEMPOTENCY))
WORKER = str(uuid.uuid5(uuid.NAMESPACE_URL, 'aivexus-worker-' + IDEMPOTENCY))
MAX_ZIP_BYTES = 16 * 1024 * 1024


def sql(name, source=JOURNAL_JS):
    found = re.search(r'const ' + name + r' = `([\s\S]*?)`;', source)
    if not found:
        raise RuntimeError('Expected Web-owned D1 SQL is missing: ' + name)
    return found.group(1)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def time_mark():
    # UTC, no timezone ambiguity; identical milliseconds are safe because
    # journal_version (not timestamp) is the transition CAS.
    from datetime import datetime, timezone
    return datetime.now(timezone.utc).isoformat(timespec='milliseconds').replace('+00:00', 'Z')


def connect(path):
    db = sqlite3.connect(path)
    db.execute('PRAGMA foreign_keys = ON')
    db.execute('PRAGMA busy_timeout = 5000')
    return db


def initialize(db):
    for filename in ('001_web_approval_reservation.sql',
                     '002_web_proposal_approval_audit.sql',
                     '003_web_execution_journal.sql'):
        db.executescript((SQL_DIR / filename).read_text())
    db.execute("""
      INSERT INTO web_project_approvals
      (owner_subject,project_id,product,status,current_revision,
       approved_revision,approved_spec_sha256,approval_id,updated_at,
       proposal_spec_sha256)
      VALUES (?,?,'aivexus-web','approved',1,1,?,?,?,?)
    """, (OWNER, PROJECT, SPEC, APPROVAL, time_mark(), SPEC))
    db.commit()
    inserted = db.execute(sql('INSERT_RESERVATION', RESERVE_JS), (
        IDEMPOTENCY, OWNER, PROJECT, 1, SPEC, EXECUTION, ATTEMPT,
        time_mark(), APPROVAL
    )).rowcount
    db.commit()
    if inserted != 1:
        raise RuntimeError('Synthetic approval did not reserve exactly once')
    duplicated = db.execute(sql('INSERT_RESERVATION', RESERVE_JS), (
        IDEMPOTENCY, OWNER, PROJECT, 1, SPEC, EXECUTION, str(uuid.uuid4()),
        time_mark(), APPROVAL
    )).rowcount
    db.commit()
    if duplicated != 0:
        raise RuntimeError('Duplicate reservation was not rejected')


def advance(db, statement, *args):
    changed = db.execute(sql(statement), args).rowcount
    db.commit()
    if changed != 1:
        raise RuntimeError('Unexpected journal transition; refusing side effects')


def state(db):
    row = db.execute("""
      SELECT status, journal_version FROM web_execution_reservations
      WHERE idempotency_key = ?
    """, (IDEMPOTENCY,)).fetchone()
    if row is None:
        raise RuntimeError('Missing journal reservation')
    return row


def history(db):
    return db.execute("""
      SELECT to_status FROM web_execution_journal_events
      WHERE idempotency_key = ? ORDER BY event_id
    """, (IDEMPOTENCY,)).fetchall()


def receipt(db):
    return db.execute(sql('READ_RECEIPT_SQL'), (IDEMPOTENCY,)).fetchone()


def validate_generated_zip(path):
    blob = path.read_bytes()
    if not blob or len(blob) > MAX_ZIP_BYTES:
        raise RuntimeError('Counter ZIP is empty or beyond MVP cap')
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        if len(names) != len(set(names)) or set(names) != {
            'index.html', 'app.js', 'styles.css', 'manifest.json'
        }:
            raise RuntimeError('Unexpected or duplicated ZIP entry')
        manifest = json.loads(archive.read('manifest.json'))
        if manifest.get('product') != 'aivexus-web':
            raise RuntimeError('Untrusted ZIP manifest')
        for name in ('index.html', 'app.js', 'styles.css'):
            stored = archive.read(name)
            source = path.parent / 'source' / name
            if stored != source.read_bytes() or (
                manifest.get('sourceSha256', {}).get(name) != digest(stored)
            ):
                raise RuntimeError('ZIP source integrity mismatch')
    generated_receipt = json.loads(
        (path.parent / 'receipt.json').read_text())
    if generated_receipt.get('artifactSha256') != digest(blob):
        raise RuntimeError('Generator receipt hash mismatch')
    return blob


def verify_browser_tests():
    # Existing Node contract tests execute actual generated JS increment/reset
    # semantics, reload persistence, deterministic ZIP, and integrity checks.
    try:
        result = subprocess.run(
            ['node', '--test', 'test/airlab/web_counter_smoke.mjs'],
            cwd=ROOT, capture_output=True, text=True,
            timeout=90, check=False
        )
        return result.returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def readback_local_artifact(root, blob):
    sha = digest(blob)
    storage_key = 'web-artifacts/' + EXECUTION + '/' + sha + '.zip'
    dest = root / storage_key
    dest.parent.mkdir(parents=True, exist_ok=True)
    # This is a *local* object-storage stand-in; never replace or overwrite.
    with dest.open('xb') as handle:
        handle.write(blob)
        handle.flush()
    stored = dest.read_bytes()
    if len(stored) != len(blob) or digest(stored) != sha or stored != blob:
        raise RuntimeError('Stored ZIP read-back did not match bytes')
    return sha, storage_key, len(stored)


def receipt_json(db):
    row = receipt(db)
    if not row:
        return None
    execution, attempt, spec, sha, storage_key, size, recorded_at = row
    return {
        'schemaVersion': 1, 'product': 'aivexus-web',
        'project': PROJECT, 'approvedRevision': 1,
        'executionId': execution, 'attemptId': attempt,
        'approvedSpecSha256': spec, 'artifactSha256': sha,
        'artifactStorageKey': storage_key,
        'artifactSizeBytes': size, 'recordedAt': recorded_at,
        'status': 'completed',
    }


def replay(root):
    db = connect(root / 'state.sqlite')
    try:
        if state(db)[0] != 'completed':
            raise RuntimeError('Interrupted/failed journal cannot auto-retry')
        result = receipt_json(db)
        if not result:
            raise RuntimeError('Completed execution has no durable receipt')
        blob = (root / result['artifactStorageKey']).read_bytes()
        if digest(blob) != result['artifactSha256'] or (
            len(blob) != result['artifactSizeBytes']
        ):
            raise RuntimeError('Persisted artifact is absent or corrupted')
        if db.execute(sql('CLAIM_SQL'), (
            IDEMPOTENCY, ATTEMPT, WORKER, time_mark()
        )).rowcount != 0:
            raise RuntimeError('Replay improperly restarted execution')
        if db.execute(sql('COMPLETE_SQL'), (
            IDEMPOTENCY, ATTEMPT, WORKER, result['artifactSha256'],
            result['artifactSizeBytes'], time_mark()
        )).rowcount != 0:
            raise RuntimeError('Replay duplicated completion')
        db.rollback()
        if [row[0] for row in history(db)] != [
            'reserved', 'running', 'completed'
        ]:
            raise RuntimeError('Durable event journal was altered')
        print(json.dumps({'ok': True, 'replayed': True,
                          'executionId': result['executionId'],
                          'artifactSha256': result['artifactSha256']}))
    finally:
        db.close()


def reconcile(root):
    db = connect(root / 'state.sqlite')
    try:
        if state(db)[0] != 'review_required':
            raise RuntimeError('Only interrupted jobs may be reconciled here')
        advance(db, 'FAIL_SQL', IDEMPOTENCY, ATTEMPT,
                WORKER, 'reconciliation', time_mark())
        assert state(db)[0] == 'failed'
        assert receipt(db) is None
        print(json.dumps({'ok': True, 'status': 'failed',
                          'reason': 'reconciliation', 'artifact': None}))
    finally:
        db.close()


def execute(root, inject_failure):
    root.mkdir(parents=True, exist_ok=False)
    db = connect(root / 'state.sqlite')
    try:
        initialize(db)
        advance(db, 'CLAIM_SQL', IDEMPOTENCY, ATTEMPT, WORKER, time_mark())
        if state(db)[0] != 'running':
            raise RuntimeError('Worker did not acquire claim')
        if inject_failure == 'interrupt':
            advance(db, 'FLAG_INTERRUPTED_SQL', IDEMPOTENCY, ATTEMPT,
                    WORKER, time_mark())
            assert receipt(db) is None
            print(json.dumps({'ok': True, 'status': 'review_required',
                              'artifact': None}))
            return

        # Actual source ZIP is generated, not merely a predicted filename.
        generated = root / 'generated'
        generate_counter(generated)
        blob = validate_generated_zip(
            generated / 'aivexus-web-counter-smoke.zip')
        if inject_failure == 'test' or not verify_browser_tests():
            advance(db, 'FAIL_SQL', IDEMPOTENCY, ATTEMPT,
                    WORKER, 'test', time_mark())
            assert receipt(db) is None
            print(json.dumps({'ok': True, 'status': 'failed',
                              'reason': 'test', 'artifact': None}))
            return

        if inject_failure == 'storage':
            advance(db, 'FAIL_SQL', IDEMPOTENCY, ATTEMPT,
                    WORKER, 'storage', time_mark())
            assert receipt(db) is None
            print(json.dumps({'ok': True, 'status': 'failed',
                              'reason': 'storage', 'artifact': None}))
            return

        sha, storage_key, size = readback_local_artifact(root, blob)
        advance(db, 'COMPLETE_SQL', IDEMPOTENCY, ATTEMPT, WORKER,
                sha, size, time_mark())
        if state(db)[0] != 'completed' or len(history(db)) != 3:
            raise RuntimeError('Receipt written without a completed journal')
        result = receipt_json(db)
        if not result or result['artifactStorageKey'] != storage_key:
            raise RuntimeError('Durable receipt disagrees with stored ZIP')
        (root / 'receipt.json').write_text(
            json.dumps(result, sort_keys=True, indent=2) + '\n',
            encoding='utf-8')
        print(json.dumps({'ok': True, 'status': 'completed',
                          'artifactSha256': sha, 'artifactSizeBytes': size,
                          'executionId': EXECUTION}))
    finally:
        db.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=pathlib.Path, required=True)
    group = parser.add_mutually_exclusive_group()
    group.add_argument('--replay', action='store_true')
    group.add_argument('--reconcile', action='store_true')
    parser.add_argument('--inject-failure',
                        choices=['none', 'interrupt', 'test', 'storage'],
                        default='none')
    args = parser.parse_args()
    if args.replay:
        replay(args.output)
    elif args.reconcile:
        reconcile(args.output)
    else:
        execute(args.output, args.inject_failure)


if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        # QA lab: do not claim completed on any exception.
        print(json.dumps({'ok': False, 'status': 'unverified',
                          'reason': type(exc).__name__}), file=sys.stderr)
        sys.exit(1)
