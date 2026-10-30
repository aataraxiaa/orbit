#!/usr/bin/env python3
"""Differential MCP fixture runner. Builds are performed separately through MobileBuildMCP.

Never points at registered/personal Orbits. Every run owns a TemporaryDirectory.
Output is evidence, not desktop host or iCloud acceptance.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
import orbit


def hashes(root):
    return {p.relative_to(root).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(root.rglob('*')) if p.is_file()}


def normalize(value, prefix):
    if isinstance(value, dict):
        return {k: normalize(v, prefix) for k, v in value.items()}
    if isinstance(value, list):
        return [normalize(v, prefix) for v in value]
    if isinstance(value, str):
        identity = json.loads((prefix / 'folder/.orbit/vault.json').read_text())['id']
        expected_key = hashlib.sha256((str((prefix / 'folder').resolve()) + '\0' + identity).encode()).hexdigest()
        expected_cache = str(prefix / 'cache' / (expected_key + '.sqlite3'))
        if value == expected_cache:
            return '$LOCAL_CACHE'
        return value.replace(str(prefix), '$LOCAL')
    return value


def expand(value, root):
    if isinstance(value, dict):
        return {k: expand(v, root) for k, v in value.items()}
    if isinstance(value, list):
        return [expand(v, root) for v in value]
    if value == '$SOURCE':
        return str(root.parent / 'source.txt')
    if value == '$FOLDER':
        return str(root)
    if isinstance(value, str) and value.startswith('$HASH:'):
        return hashlib.sha256((root / value[6:]).read_bytes()).hexdigest()
    return value


class Server:
    def __init__(self, command, prefix):
        self.prefix = prefix
        self.env = dict(os.environ, ORBIT_CONFIG=str(prefix / 'config.json'),
                        ORBIT_CACHE=str(prefix / 'cache'), ORBIT_STATE=str(prefix / 'state'))
        self.process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE, text=True, env=self.env)

    def call(self, action, arguments):
        message = {'jsonrpc': '2.0', 'id': 1, 'method': 'tools/call',
                   'params': {'name': 'orbit_' + action, 'arguments': arguments}}
        self.process.stdin.write(json.dumps(message, ensure_ascii=False) + '\n')
        self.process.stdin.flush()
        line = self.process.stdout.readline()
        if not line:
            raise RuntimeError('MCP process stopped: ' + self.process.stderr.read())
        result = json.loads(line)
        for block in result.get('result', {}).get('content', []):
            if block.get('type') == 'text':
                block['text'] = json.loads(block['text'])
        return normalize(result, self.prefix)

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--swift', type=Path, required=True, help='Previously built native orbit-mcp executable')
    parser.add_argument('--fixtures', type=Path, default=ROOT / 'tests/fixtures/compatibility/commands.json')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--deterministic', action='store_true', help='Use development reference driver; --swift must point to orbit-fixture')
    args = parser.parse_args()
    fixture = json.loads(args.fixtures.read_text())
    report = {'reference_revision': json.loads((ROOT / 'Sources/OrbitCore/Resources/contract.json').read_text())['reference_revision'],
              'fixture': str(args.fixtures.resolve().relative_to(ROOT)), 'cases': [],
              'binary_sha256': hashlib.sha256(args.swift.read_bytes()).hexdigest(),
              'native_host_acceptance': 'NOT VERIFIED', 'icloud_acceptance': 'NOT VERIFIED'}
    with tempfile.TemporaryDirectory(prefix='orbit-swift-parity-') as temp:
        base = Path(temp).resolve()
        seed = base / 'seed'
        previous = dict(os.environ)
        try:
            os.environ.update(ORBIT_CONFIG=str(base / 'seed-config.json'), ORBIT_CACHE=str(base / 'seed-cache'), ORBIT_STATE=str(base / 'seed-state'))
            orbit.setup(str(seed), 'Seed', create=True)
        finally:
            os.environ.clear(); os.environ.update(previous)
        servers = []
        for name, command in [('python', [sys.executable, str(ROOT / ('scripts/compatibility_reference.py' if args.deterministic else 'scripts/mcp_server.py'))]), ('swift', [str(args.swift.resolve())])]:
            prefix = base / name
            shutil.copytree(seed, prefix / 'folder')
            identity = json.loads((seed / '.orbit/vault.json').read_text())['id']
            (prefix / 'config.json').write_text(json.dumps({'schema': 2, 'orbits': {'Test': {'path': str(prefix / 'folder'), 'vault_id': identity}}}))
            (prefix / 'source.txt').write_text('Original source bytes. Orchard pears and garden plans.\n')
            servers.append(Server(command, prefix))
        try:
            for case in fixture['calls']:
                outputs = []
                for server in servers:
                    try:
                        outputs.append(server.call(case['action'], expand(case['arguments'], server.prefix / 'folder')))
                    except FileNotFoundError as exc:
                        outputs.append({'fixture_precondition_error': str(exc).replace(str(server.prefix), '$LOCAL')})
                stored = [hashes(s.prefix / 'folder') for s in servers]
                same_result, same_storage = outputs[0] == outputs[1], stored[0] == stored[1]
                expected_error = case.get('expect_error', False)
                behavior_ok = all(('error' in output or output.get('result', {}).get('isError', False)) == expected_error for output in outputs)
                row = {'name': case['name'], 'result_equal': same_result, 'stored_hashes_equal': same_storage,
                       'expected_behavior': behavior_ok,
                       'status': 'VERIFIED' if same_result and same_storage and behavior_ok else 'NOT VERIFIED'}
                if not same_result or not behavior_ok:
                    row.update(python=outputs[0], swift=outputs[1])
                if not same_storage:
                    row['stored_differences'] = {key: [stored[0].get(key), stored[1].get(key)] for key in sorted(stored[0].keys() | stored[1].keys()) if stored[0].get(key) != stored[1].get(key)}
                report['cases'].append(row)
        finally:
            for server in servers:
                server.close()
    report['passed'] = sum(c['status'] == 'VERIFIED' for c in report['cases'])
    report['total'] = len(report['cases'])
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({k: report[k] for k in ('passed', 'total')}))
    return report['passed'] != report['total']


if __name__ == '__main__':
    sys.exit(main())
