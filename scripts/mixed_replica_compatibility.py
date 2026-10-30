#!/usr/bin/env python3
"""Replay language-neutral transport fixtures through Python and native Swift MCP.

Build the executable separately with MobileBuildMCP. This runner only launches
already-built programs. It owns disposable folders, registries, caches and state.
Copied envelopes simulate a transport, not native iCloud or desktop acceptance.
"""
from __future__ import annotations

import argparse
import copy
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import selectors
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
import orbit
import replication


def disposable_path(root, relative):
    relative = Path(relative)
    if relative.is_absolute() or '..' in relative.parts:
        raise ValueError('Fixture path must stay inside its disposable folder')
    destination = root / relative
    if not destination.resolve().is_relative_to(root.resolve()):
        raise ValueError('Fixture path escapes its disposable folder')
    return destination


def stored(root):
    return {p.relative_to(root).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(root.rglob('*')) if p.is_file()}


def normalize(value, prefix):
    if isinstance(value, dict):
        return {k: normalize(v, prefix) for k, v in value.items()}
    if isinstance(value, list):
        return [normalize(v, prefix) for v in value]
    return value.replace(str(prefix), '$WORLD') if isinstance(value, str) else value


class Server:
    def __init__(self, command, prefix, timeout):
        self.command, self.prefix, self.timeout = command, prefix, timeout
        self.env = dict(os.environ, ORBIT_CONFIG=str(prefix / 'config.json'),
                        ORBIT_CACHE=str(prefix / 'cache'), ORBIT_STATE=str(prefix / 'state'))
        self.start()

    def start(self):
        self.stderr = tempfile.TemporaryFile(mode='w+b')
        self.process = subprocess.Popen(self.command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=self.stderr, env=self.env)
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        self.buffer = b''

    def call(self, action, arguments):
        message = {'jsonrpc': '2.0', 'id': 1, 'method': 'tools/call',
                   'params': {'name': 'orbit_' + action, 'arguments': arguments}}
        raw = (json.dumps(message, ensure_ascii=False) + '\n').encode('utf-8')
        self.process.stdin.write(raw); self.process.stdin.flush()
        deadline = time.monotonic() + self.timeout
        while b'\n' not in self.buffer:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not self.selector.select(max(0, remaining)):
                raise TimeoutError(f'{action}: MCP request exceeded {self.timeout}s')
            chunk = os.read(self.process.stdout.fileno(), 65536)
            if not chunk:
                self.stderr.seek(0)
                raise RuntimeError('MCP stopped: ' + self.stderr.read().decode('utf-8', errors='replace'))
            self.buffer += chunk
        line, self.buffer = self.buffer.split(b'\n', 1)
        response = json.loads(line)
        if 'error' in response:
            return {'kind': 'rpc-error', 'value': response['error']}
        result = response['result']
        blocks = [b for b in result.get('content', []) if b.get('type') == 'text']
        if len(blocks) != 1:
            raise ValueError('Expected one MCP text result')
        return {'kind': 'tool-error' if result.get('isError') else 'success',
                'value': json.loads(blocks[0]['text'])}

    def close(self, kill=False):
        if self.process.poll() is None:
            if kill:
                self.process.kill()
            else:
                self.process.stdin.close()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill(); self.process.wait()
        self.selector.close(); self.stderr.close()

    def restart(self):
        self.close(kill=True); self.start()


class World:
    def __init__(self, base, seed, commands, timeout):
        self.base, self.servers, self.results, self.requests = base, {}, {}, {}
        for name, command in commands.items():
            prefix = base / name
            shutil.copytree(seed, prefix / 'folder')
            identity = json.loads((seed / '.orbit/vault.json').read_bytes())['id']
            (prefix / 'config.json').write_text(json.dumps({'schema': 2, 'orbits': {
                'Test': {'path': str(prefix / 'folder'), 'vault_id': identity}}}))
            self.servers[name] = Server(command, prefix, timeout)

    def folder(self, replica):
        return self.servers[replica].prefix / 'folder'

    def expand(self, value, replica):
        if isinstance(value, dict):
            return {k: self.expand(v, replica) for k, v in value.items()}
        if isinstance(value, list):
            return [self.expand(v, replica) for v in value]
        if isinstance(value, str):
            if value.startswith('$HASH:'):
                return hashlib.sha256(disposable_path(self.folder(replica), value[6:]).read_bytes()).hexdigest()
            if value.startswith('$REF:'):
                identifier, _, pointer = value[5:].partition('#')
                node = self.results[identifier]
                for key in pointer.strip('/').split('/') if pointer.strip('/') else []:
                    key = key.replace('~1', '/').replace('~0', '~')
                    node = node[int(key)] if isinstance(node, list) else node[key]
                return copy.deepcopy(node)
        return value

    def step(self, step):
        kind = step['kind']
        replica = step.get('replica')
        if kind in ('call', 'retry'):
            if kind == 'retry':
                action, arguments = copy.deepcopy(self.requests[step['request']])
            else:
                action, arguments = step['action'], self.expand(step.get('arguments', {}), replica)
            if 'request' in step and kind == 'call':
                self.requests[step['request']] = (action, copy.deepcopy(arguments))
            result = self.servers[replica].call(action, arguments)
            if step.get('save'):
                self.results[step['save']] = result['value']
            return result
        if kind == 'deliver':
            source, target = self.folder(step['from']), self.folder(step['to'])
            operation = self.expand(step.get('operation'), step['from'])
            copied = []
            for directory in step.get('directories', ['commits', 'observations']):
                if directory not in ('commits', 'observations'):
                    raise ValueError('Only immutable evidence may use the fixture transport')
                folder = source / '.orbit' / directory
                for path in sorted(folder.glob('*.json')):
                    if directory == 'commits' and operation and path.stem != operation:
                        continue
                    destination = target / '.orbit' / directory / path.name
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    raw = path.read_bytes()
                    if destination.exists() and destination.read_bytes() != raw:
                        raise ValueError('Immutable transport identity collision')
                    destination.write_bytes(raw); copied.append(destination.relative_to(target).as_posix())
            return {'kind': 'transport', 'copied': copied}
        if kind == 'project':
            path = step['path']
            target = disposable_path(self.folder(step['to']), path)
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(disposable_path(self.folder(step['from']), path).read_bytes())
            return {'kind': 'project', 'path': path}
        if kind == 'external':
            path = disposable_path(self.folder(replica), step['path'])
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(step['content'].encode('utf-8'))
            return {'kind': 'external', 'path': step['path'], 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
        if kind == 'permissions':
            path = disposable_path(self.folder(replica), step.get('path', ''))
            path.chmod(int(step['mode'], 8))
            return {'kind': 'permissions', 'mode': step['mode']}
        if kind == 'restart':
            self.servers[replica].restart()
            return {'kind': 'restart'}
        raise ValueError('Unknown fixture step: ' + kind)

    def storage(self):
        return {name: stored(self.folder(name)) for name in self.servers}

    def close(self):
        for server in self.servers.values():
            server.close()
        # Restore fixture-injected permissions before TemporaryDirectory cleanup.
        for folder in self.base.glob('*/folder'):
            folder.chmod(0o755)
            for path in folder.rglob('*'):
                if path.is_dir():
                    path.chmod(0o755)


def semantic_result(value, policy):
    value = copy.deepcopy(value)
    if policy == 'permission-receipt':
        if value.get('kind') != 'success':
            raise ValueError('Projection failure must retain a successful durable receipt')
        receipt = value['value']
        if receipt.get('status') != 'committed' or receipt.get('durability') != 'local' or receipt.get('verified') is not False:
            raise ValueError('Projection failure lost local acceptance')
        sync = receipt.get('sync', {})
        error = sync.get('error', '')
        if sync.get('status') != 'interrupted' or not any(part in error.lower() for part in ('permission denied', 'code=13', 'code=513', 'permissions', 'eacces')):
            raise ValueError('Expected an interrupted projection due to denied filesystem access: ' + error)
        sync['error'] = '$PERMISSION_DENIED'
    return value


def assert_result(value, expected, counts=None):
    for pointer, wanted in expected.items():
        node = value
        for key in pointer.strip('/').split('/'):
            node = node[int(key)] if isinstance(node, list) else node[key]
        if node != wanted:
            raise AssertionError(f'{pointer}: expected {wanted!r}, observed {node!r}')
    for pointer, wanted in (counts or {}).items():
        node = value
        for key in pointer.strip('/').split('/'):
            node = node[int(key)] if isinstance(node, list) else node[key]
        if len(node) != wanted:
            raise AssertionError(f'{pointer}: expected {wanted} entries, observed {len(node)}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--swift', type=Path, required=True)
    parser.add_argument('--fixtures', type=Path, default=ROOT / 'tests/fixtures/compatibility/replica-transport.json')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--timeout', type=float, default=10)
    args = parser.parse_args()
    fixture = json.loads(args.fixtures.read_text())
    python = [sys.executable, str(ROOT / 'scripts/mcp_server.py')]
    swift = [str(args.swift.resolve())]
    report = {'reference_revision': fixture['reference_revision'], 'fixture': str(args.fixtures.relative_to(ROOT)),
              'native_binary_sha256': hashlib.sha256(args.swift.read_bytes()).hexdigest(),
              'cases': [], 'native_host_acceptance': 'NOT VERIFIED', 'icloud_acceptance': 'NOT VERIFIED',
              'transport': 'deterministic file delivery',
              'faults': 'denied projection writes, stale physical checkout, killed and restarted MCP processes'}
    with tempfile.TemporaryDirectory(prefix='orbit-mixed-replica-') as temporary:
        base = Path(temporary).resolve(); seed = base / 'seed'
        for path, content in fixture['files'].items():
            destination = disposable_path(seed, path); destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(content.encode('utf-8'))
        previous = dict(os.environ)
        try:
            os.environ.update(ORBIT_STATE=str(base / 'seed-state'))
            replication.seed(seed, {path: content for path, content in fixture['files'].items() if path.endswith('.md')})
        finally:
            os.environ.clear(); os.environ.update(previous)
        for scenario in fixture['scenarios']:
            for native_replica in ('a', 'b'):
                prefix = base / (scenario['name'] + '-' + native_replica)
                worlds = [World(prefix / 'reference', seed, {r: python for r in ('a','b','c')}, args.timeout),
                          World(prefix / 'mixed', seed, {r: swift if r == native_replica else python for r in ('a','b','c')}, args.timeout)]
                try:
                    for step in scenario['steps']:
                        row = {'scenario': scenario['name'], 'native_replica': native_replica, 'step': step['name']}
                        outputs = []; errors = []
                        for world in worlds:
                            try:
                                output = normalize(world.step(step), world.base)
                                output = semantic_result(output, step.get('comparison'))
                                expected = {'/kind': 'success'} if step['kind'] in ('call', 'retry') else {}
                                expected.update(step.get('expect', {}))
                                assert_result(output, expected, step.get('expect_count'))
                                outputs.append(output); errors.append(None)
                            except Exception as error:
                                outputs.append(None); errors.append(normalize(str(error), world.base))
                        storage = [world.storage() for world in worlds]
                        for manifest in storage:
                            for files in manifest.values():
                                if any(path.endswith(('.sqlite', '.sqlite-wal', '.sqlite-shm')) or path in ('.orbit/write.lock', '.orbit/checkout.json') for path in files):
                                    errors = ['Device-local state leaked into synced data', 'Device-local state leaked into synced data']
                        row['result_sha256'] = [hashlib.sha256(json.dumps(output, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode()).hexdigest() for output in outputs]
                        row['storage_manifest_sha256'] = [hashlib.sha256(json.dumps(manifest, sort_keys=True, separators=(',', ':')).encode()).hexdigest() for manifest in storage]
                        row['result_equal'] = errors == [None,None] and outputs[0] == outputs[1]
                        row['stored_hashes_equal'] = storage[0] == storage[1]
                        row['status'] = 'VERIFIED' if row['result_equal'] and row['stored_hashes_equal'] else 'NOT VERIFIED'
                        if not row['result_equal']:
                            row.update(reference=outputs[0], mixed=outputs[1], errors=errors)
                        if not row['stored_hashes_equal']:
                            row['stored_differences'] = {replica: {path: [storage[0][replica].get(path), storage[1][replica].get(path)]
                                for path in sorted(storage[0][replica].keys() | storage[1][replica].keys())
                                if storage[0][replica].get(path) != storage[1][replica].get(path)} for replica in storage[0]}
                        report['cases'].append(row)
                        if any(errors):
                            break
                finally:
                    for world in worlds:
                        world.close()
        worlds = [World(base / 'local-lock-reference', seed, {'a': python}, args.timeout),
                  World(base / 'local-lock-mixed', seed, {'a': swift}, args.timeout)]
        outputs, errors = [], []
        try:
            for world in worlds:
                previous = dict(os.environ)
                try:
                    os.environ.update(ORBIT_STATE=str(world.servers['a'].prefix / 'state'))
                    with concurrent.futures.ThreadPoolExecutor(max_workers=1) as executor:
                        with replication.local_lock(world.folder('a')):
                            future = executor.submit(world.servers['a'].call, 'sync', {'orbit': 'Test', 'action': 'reconcile'})
                            time.sleep(0.2)
                            blocked = not future.done()
                        output = normalize(future.result(timeout=args.timeout + 1), world.base)
                    assert_result(output, {'/kind': 'success', '/value/status': 'ready'})
                    if not blocked:
                        raise AssertionError('MCP process bypassed the held Python local lock')
                    outputs.append(output); errors.append(None)
                except Exception as error:
                    outputs.append(None); errors.append(normalize(str(error), world.base))
                finally:
                    os.environ.clear(); os.environ.update(previous)
            equal = errors == [None, None] and outputs[0] == outputs[1]
            same_storage = worlds[0].storage() == worlds[1].storage()
            report['cases'].append({'scenario': 'mixed-local-lock-exclusion', 'native_replica': 'a',
                'step': 'native-process-waits-for-python-lock', 'result_equal': equal,
                'stored_hashes_equal': same_storage, 'status': 'VERIFIED' if equal and same_storage else 'NOT VERIFIED',
                **({} if equal else {'reference': outputs[0], 'mixed': outputs[1], 'errors': errors})})
        finally:
            for world in worlds:
                world.close()
    report['passed'] = sum(row['status'] == 'VERIFIED' for row in report['cases']); report['total'] = len(report['cases'])
    report['complete_fixture'] = report['total'] == sum(len(s['steps']) for s in fixture['scenarios']) * 2 + 1
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({key: report[key] for key in ('passed','total','complete_fixture')}))
    return report['passed'] != report['total'] or not report['complete_fixture']


if __name__ == '__main__':
    sys.exit(main())
