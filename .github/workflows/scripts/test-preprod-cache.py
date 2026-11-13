#!/usr/bin/env python3
"""Exercise preprod cache scripts with a filesystem-backed S3 fixture and fake Docker.

Run: python3 .github/workflows/scripts/test-preprod-cache.py
Requires bash and jq; never contacts AWS or starts a container.
"""
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parent
S3 = "s3://fixture/db-preprod"

S5CMD = r'''
import fnmatch, json, os, shutil, sys
from pathlib import Path
args = sys.argv[1:]
with open(os.environ['CALL_LOG'], 'a') as log:
    log.write(json.dumps(args) + '\n')
while args[0].startswith('--'):
    flag = args.pop(0)
    if flag == '--log': args.pop(0)
cmd = args.pop(0)
if os.environ.get('FAIL_OPERATION') == cmd and os.environ.get('FAIL_CONTAINS', '') in args[0]:
    print(json.dumps({'operation':cmd,'error':'AccessDenied'}), file=sys.stderr)
    sys.exit(1)
root = Path(os.environ['BUCKET'])
def local(value):
    return root / value.removeprefix('s3://fixture/') if value.startswith('s3://') else Path(value)
def copy(src, dst):
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(src, dst)
if cmd == 'ls':
    prefix = args[0].rstrip('/') + '/'
    path = local(prefix)
    children = sorted(path.iterdir()) if path.is_dir() else []
    if not children:
        print(json.dumps({'operation':'ls','error':'no object found'}), file=sys.stderr)
        sys.exit(1)
    for child in children:
        print(json.dumps({'key':prefix + child.name + ('/' if child.is_dir() else ''),
                          'type':'directory' if child.is_dir() else 'file'}))
elif cmd == 'sync':
    delete = args[0] == '--delete'
    if delete: args.pop(0)
    src, dst = local(args[0].removesuffix('*')), local(args[1])
    dst.mkdir(parents=True, exist_ok=True)
    if not src.is_dir(): sys.exit(1)
    if delete:
        for path in dst.rglob('*'):
            if path.is_file() and not (src / path.relative_to(dst)).exists(): path.unlink()
    for path in src.rglob('*'):
        if path.is_file(): copy(path, dst / path.relative_to(src))
elif cmd == 'cp':
    copy(local(args[0]), local(args[1]))
elif cmd == 'rm':
    value = args[0]
    if value.endswith('/*'):
        path = local(value[:-2])
        shutil.rmtree(path)
    else: local(value).unlink()
else: raise AssertionError(cmd)
'''

DOCKER = r'''
import json, os, sys
from pathlib import Path
args=sys.argv[1:]
with open(os.environ['DOCKER_LOG'],'a') as log: log.write(json.dumps(args)+'\n')
if args[0]=='run': print('fixture-container')
elif args[0]=='inspect': print('false' if os.environ.get('NODE_STOPPED') else 'true')
elif args[0]=='logs': print('fixture node diagnostics',file=sys.stderr)
elif args[0]=='exec':
    if args[args.index('--testnet-magic') + 1] != '1':
        raise AssertionError('Expected Preprod network magic')
    if args[-2:] != ['--socket-path','/ipc/node.socket']:
        print('Missing: --socket-path',file=sys.stderr);sys.exit(1)
    count=Path(os.environ['QUERY_COUNT'])
    n=int(count.read_text()) if count.exists() else 0
    count.write_text(str(n+1))
    if n < int(os.environ.get('QUERY_FAILURES','0')):
        print('fixture query failure',file=sys.stderr);sys.exit(1)
    progress=json.loads(os.environ.get('PROGRESS','["100.00"]'))
    print(json.dumps({'syncProgress':progress[min(n,len(progress)-1)]}))
else: raise AssertionError(args)
'''


class CacheTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bucket = self.root / 'bucket'
        self.cache = self.bucket / 'db-preprod'
        self.db = self.root / 'db'
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.log = self.root / 'calls'
        self.env = os.environ | {
            'PATH': str(self.bin) + os.pathsep + os.environ['PATH'],
            'BUCKET': str(self.bucket), 'CALL_LOG': str(self.log),
            'RUNNER_TEMP': str(self.root), 'CONFDIR': str(self.root / 'config'),
            'CARDANO_NODE_VERSION': '11.1.3', 'DOCKER_LOG': str(self.root / 'docker-log'),
            'QUERY_COUNT': str(self.root / 'query-count'),
        }
        for name, body in [('s5cmd', S5CMD), ('docker', DOCKER), ('sleep', 'import time; time.sleep(0.01)')]:
            path = self.bin / name
            path.write_text(f'#!{sys.executable}\n' + body)
            path.chmod(0o755)

    def put(self, root, name, content='fixture'):
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)

    def seed(self):
        for name in ['immutable/00000.chunk', 'immutable/00001.chunk', 'volatile/blocks-1.dat',
                     'protocolMagicId', 'clean', 'lock']:
            self.put(self.cache, name)
        for slot in ['77', '900', '4000', '12000', '2345678_db-analyser']:
            self.put(self.cache, f'ledger/{slot}/state')

    def local_db(self):
        for name in ['immutable/00000.chunk', 'immutable/00001.chunk', 'volatile/blocks-9.dat',
                     'ledger/50000/state', 'ledger/50100/state', 'protocolMagicId', 'clean']:
            self.put(self.db, name)
        self.db.with_suffix('.restored-chunks').write_text('2\n')

    def run_script(self, name, ok=True, extra=None, args=None):
        result = subprocess.run(['bash', str(SCRIPTS / name), *(args or [S3, str(self.db)])],
                                env=self.env | (extra or {}), capture_output=True, text=True, timeout=15)
        if ok:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def test_restore_selects_two_newest_and_keeps_volatile_and_markers(self):
        self.seed()
        self.run_script('preprod-db-restore.sh')
        self.assertEqual(sorted(p.name for p in (self.db / 'ledger').iterdir()), ['12000', '2345678_db-analyser'])
        for name in ['volatile/blocks-1.dat', 'clean', 'protocolMagicId']:
            self.assertTrue((self.db / name).exists())
        self.assertFalse((self.db / 'lock').exists())
        self.assertEqual(self.db.with_suffix('.restored-chunks').read_text().strip(), '2')

    def test_cold_cache(self):
        self.run_script('preprod-db-restore.sh')
        self.assertEqual(self.db.with_suffix('.restored-chunks').read_text().strip(), '0')

    def test_progress_error_does_not_override_restore_result(self):
        self.seed()
        real_du = shutil.which('du')
        marker = self.root / 'du-failed'
        stub = self.bin / 'du'
        stub.write_text(f'''#!{sys.executable}
import os, sys
from pathlib import Path
marker = Path({str(marker)!r})
if not marker.exists():
    marker.touch()
    print("du: cannot access temporary download file: No such file or directory", file=sys.stderr)
    sys.exit(1)
os.execv({real_du!r}, [{real_du!r}, *sys.argv[1:]])
''')
        stub.chmod(0o755)
        for fail_download in [False, True]:
            with self.subTest(fail_download=fail_download):
                marker.unlink(missing_ok=True)
                extra = {'FAIL_OPERATION':'sync'} if fail_download else {}
                result = self.run_script('preprod-db-restore.sh', ok=not fail_download, extra=extra)
                self.assertTrue(marker.exists(), 'Progress probe must exercise the du failure')
                if fail_download:
                    self.assertIn('Restore attempt 3 finished (exit 1)', result.stdout)
                    self.assertIn('AccessDenied', result.stdout)
                    self.assertFalse(self.db.with_suffix('.restored-chunks').exists())
                else:
                    self.assertTrue((self.db / 'ledger/12000/state').exists())
                    self.assertEqual(self.db.with_suffix('.restored-chunks').read_text().strip(), '2')

    def test_listing_failure_is_not_a_cold_cache(self):
        result = self.run_script('preprod-db-restore.sh', ok=False, extra={'FAIL_OPERATION':'ls'})
        self.assertIn('AccessDenied', result.stdout)
        self.assertFalse(self.db.with_suffix('.restored-chunks').exists())

    def test_ledger_listing_failure_is_not_an_empty_ledger(self):
        self.seed()
        self.run_script('preprod-db-restore.sh', ok=False,
                        extra={'FAIL_OPERATION':'ls', 'FAIL_CONTAINS':'/ledger/'})
        self.assertFalse(self.db.with_suffix('.restored-chunks').exists())

    def test_partial_restore_does_not_enable_save(self):
        self.seed()
        self.run_script('preprod-db-restore.sh', ok=False,
                        extra={'FAIL_OPERATION':'sync', 'FAIL_CONTAINS':'/ledger/12000/'})
        self.assertFalse(self.db.with_suffix('.restored-chunks').exists())

    def test_missing_clean_marker_is_optional_on_restore(self):
        self.seed()
        (self.cache / 'clean').unlink()
        self.run_script('preprod-db-restore.sh')
        self.assertFalse((self.db / 'clean').exists())

    def test_marker_transfer_error_is_not_ignored(self):
        self.seed()
        self.run_script('preprod-db-restore.sh', ok=False,
                        extra={'FAIL_OPERATION':'cp', 'FAIL_CONTAINS':'protocolMagicId'})
        self.assertFalse(self.db.with_suffix('.restored-chunks').exists())

    def test_save_uploads_before_pruning_and_publishes_clean_last(self):
        self.seed()
        self.local_db()
        self.run_script('preprod-db-save.sh')
        self.assertEqual(sorted(p.name for p in (self.cache / 'ledger').iterdir()), ['50000','50100'])
        self.assertEqual(sorted(p.name for p in (self.cache / 'volatile').iterdir()), ['blocks-9.dat'])
        calls=self.calls()
        uploads=[i for i,c in enumerate(calls) if c[-2].startswith(str(self.db / 'ledger'))]
        prunes=[i for i,c in enumerate(calls) if 'rm' in c and '/ledger/' in c[-1]]
        self.assertLess(max(uploads),min(prunes))
        self.assertEqual(calls[-1][-3:],['cp',str(self.db / 'clean'),S3+'/clean'])
        self.assertFalse(any('rm' in c and '/immutable' in c[-1] for c in calls))

    def test_failed_upload_does_not_prune_or_publish_clean(self):
        self.seed()
        self.local_db()
        self.run_script('preprod-db-save.sh',ok=False,
                        extra={'FAIL_OPERATION':'sync','FAIL_CONTAINS':'/ledger/50100/'})
        self.assertTrue((self.cache / 'ledger/900/state').exists())
        self.assertFalse((self.cache / 'clean').exists())

    def test_save_requires_successful_restore_and_clean_shutdown(self):
        for missing in ['clean','protocolMagicId','baseline']:
            with self.subTest(missing=missing):
                self.local_db()
                path = self.db.with_suffix('.restored-chunks') if missing=='baseline' else self.db / missing
                path.unlink()
                self.run_script('preprod-db-save.sh',ok=False)
        self.assertEqual(self.calls(),[])

    def test_save_rejects_truncated_database(self):
        self.local_db()
        (self.db / 'immutable/00001.chunk').unlink()
        self.run_script('preprod-db-save.sh',ok=False)
        self.assertEqual(self.calls(),[])

    def test_save_listing_failure_precedes_all_writes(self):
        self.local_db()
        self.run_script('preprod-db-save.sh',ok=False,extra={'FAIL_OPERATION':'ls'})
        self.assertTrue(all('ls' in c for c in self.calls()))

    def test_empty_local_ledger_preserves_cached_snapshots(self):
        self.seed()
        self.local_db()
        shutil.rmtree(self.db / 'ledger')
        self.run_script('preprod-db-save.sh')
        self.assertTrue((self.cache / 'ledger/900/state').exists())

    def test_save_preserves_preview_prefix_in_shared_bucket(self):
        self.seed()
        self.local_db()
        preview = self.bucket / 'db-preview'
        self.put(preview, 'ledger/900/state', 'preview ledger')
        self.put(preview, 'volatile/blocks-old.dat', 'preview volatile')
        self.put(preview, 'clean', 'preview clean')
        before = {p.relative_to(preview): p.read_bytes() for p in preview.rglob('*') if p.is_file()}
        self.run_script('preprod-db-save.sh')
        after = {p.relative_to(preview): p.read_bytes() for p in preview.rglob('*') if p.is_file()}
        self.assertEqual(before, after)


    def node_socket(self):
        (self.root / 'ipc').mkdir()
        sock=socket.socket(socket.AF_UNIX)
        sock.bind(str(self.root / 'ipc/node.socket'))
        self.addCleanup(sock.close)

    def test_sync_passes_explicit_socket_and_reaches_target(self):
        self.node_socket()
        result=self.run_script('preprod-node-sync.sh',args=['1'],extra={'PROGRESS':'["97.00","100.00"]'})
        self.assertIn('Reached target sync level',result.stdout)
        self.assertEqual((self.root/'query-count').read_text(),'2')

    def test_query_failure_is_visible_and_bounded(self):
        self.node_socket()
        result=self.run_script('preprod-node-sync.sh',ok=False,args=['1'],extra={'QUERY_FAILURES':'100'})
        self.assertIn('fixture query failure',result.stderr)
        self.assertIn('Twelve consecutive',result.stderr)
        self.assertEqual((self.root/'query-count').read_text(),'12')

    def test_sync_detects_stopped_node(self):
        result=self.run_script('preprod-node-sync.sh',ok=False,args=['1'],extra={'NODE_STOPPED':'1'})
        self.assertIn('stopped before reaching',result.stderr)

    def test_sync_validates_target_and_accepts_zero(self):
        for target in ['-1','1.1','garbage']:
            self.run_script('preprod-node-sync.sh',ok=False,args=[target])
        self.node_socket()
        self.run_script('preprod-node-sync.sh',args=['0'],extra={'PROGRESS':'["0"]'})


    def test_sync_reports_started_node_and_uses_preprod_database(self):
        self.node_socket()
        output = self.root / 'outputs'
        self.run_script('preprod-node-sync.sh', args=['0.9999'],
                        extra={'GITHUB_OUTPUT':str(output), 'PROGRESS':'["99.99"]'})
        self.assertEqual(output.read_text(), 'node-started=true\n')
        calls = [json.loads(line) for line in (self.root / 'docker-log').read_text().splitlines()]
        self.assertIn(str(self.root / 'db-preprod') + ':/db', calls[0])

    def test_invalid_sync_input_does_not_report_started_node(self):
        output = self.root / 'outputs'
        self.run_script('preprod-node-sync.sh', ok=False, args=['"1"'],
                        extra={'GITHUB_OUTPUT':str(output)})
        self.assertFalse(output.exists())
        self.assertFalse((self.root / 'docker-log').exists())

    def test_sync_deadline_is_bounded(self):
        self.node_socket()
        result = self.run_script('preprod-node-sync.sh', ok=False, args=['1'],
                                 extra={'SYNC_TIMEOUT_SECONDS':'1', 'PROGRESS':'["90"]'})
        self.assertIn('Timed out waiting for node to sync', result.stderr)


if __name__ == '__main__':
    unittest.main(verbosity=2)
