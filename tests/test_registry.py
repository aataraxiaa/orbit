import concurrent.futures
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import uuid

from test_orbit import note, plan
import orbit
import registry
import test_mcp
from test_mcp import call

class RegistryTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix='orbit-registry-')
        self.addCleanup(temp.cleanup)
        self.base = Path(temp.name).resolve()
        self.cfg = self.base / 'config/config.json'
        self.cache = self.base / 'cache'
        env = {k: v for k, v in os.environ.items() if not k.startswith('ORBIT_')}
        env.update(ORBIT_CONFIG=str(self.cfg), ORBIT_CACHE=str(self.cache))
        self.environment = patch.dict(os.environ, env, clear=True)
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.personal, self.work = self.base / 'personal', self.base / 'work'

    def register(self, root=None, name='Personal', **kwargs):
        return orbit.dispatch('setup', dict(path=str(root or self.personal), name=name, create=True, **kwargs))

    def test_link_existing_folder_and_rename_preserve_content_and_identity(self):
        self.personal.mkdir()
        original = b'User-owned Markdown without Orbit metadata.\n'
        (self.personal / 'Existing.md').write_bytes(original)
        linked = orbit.dispatch('setup', {'path': str(self.personal), 'name': 'Orbit'})
        data = json.loads(self.cfg.read_text())
        data['custom'] = {'keep': True}
        data['orbits']['Orbit']['custom'] = ['keep']
        self.cfg.write_text(json.dumps(data))
        before = {str(p.relative_to(self.personal)): p.read_bytes() for p in self.personal.rglob('*') if p.is_file()}
        result = orbit.dispatch('rename', {'orbit': 'orbit', 'name': 'Work'})
        self.assertEqual(result['status'], 'renamed')
        self.assertEqual(result['previous_name'], 'Orbit')
        self.assertEqual(result['target']['path'], str(self.personal))
        self.assertEqual(result['target']['vault_id'], linked['target']['vault_id'])
        updated = json.loads(self.cfg.read_text())
        self.assertEqual(updated['custom'], data['custom'])
        self.assertEqual(updated['orbits']['Work'], data['orbits']['Orbit'])
        self.assertEqual(before, {str(p.relative_to(self.personal)): p.read_bytes() for p in self.personal.rglob('*') if p.is_file()})
        self.assertEqual((self.personal / 'Existing.md').read_bytes(), original)
        with self.assertRaisesRegex(orbit.OrbitError, 'Unknown Orbit'):
            orbit.dispatch('apply', {'orbit': 'Orbit', 'plan': plan()})
        self.assertFalse(self.cache.exists())

    def test_rename_conflicts_invalid_names_and_noop_do_not_write(self):
        self.register()
        self.register(self.work, 'Work')
        before = self.cfg.read_bytes()
        for source, name in [('Personal', 'work'), ('missing', 'New'), ('Personal', ' bad'), ('Personal', '')]:
            with self.subTest(source=source, name=name), self.assertRaises(orbit.OrbitError):
                registry.rename(source, name)
            self.assertEqual(self.cfg.read_bytes(), before)
        result = registry.rename('personal', 'Personal')
        self.assertEqual(result['status'], 'unchanged')
        self.assertEqual(self.cfg.read_bytes(), before)
        result = registry.rename('Personal', 'PERSONAL')
        self.assertEqual(result['status'], 'renamed')
        self.assertEqual(registry.resolve('personal').name, 'PERSONAL')

    def test_cli_rename(self):
        self.register()
        result = subprocess.run([sys.executable, str(Path(orbit.__file__)), '--orbit', 'Personal', 'rename', '--name', 'Work'],
                                capture_output=True, text=True, env=os.environ.copy(), timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)['target']['name'], 'Work')

    def test_cli_selection_errors_remain_structured(self):
        for configured in (False, True):
            if configured:
                self.register()
                self.register(self.work, 'Work')
            result = subprocess.run([sys.executable, str(Path(orbit.__file__)), 'doctor'],
                                    capture_output=True, text=True, env=os.environ.copy(), timeout=10)
            self.assertEqual(result.returncode, 1)
            self.assertEqual(result.stdout, '')
            error = json.loads(result.stderr)
            self.assertIn('multiple' if configured else 'zero', error['error'])


    def test_cli_named_selection(self):
        self.register()
        self.register(self.work, 'Work')
        result = subprocess.run([sys.executable, str(Path(orbit.__file__)), '--orbit', 'Work', 'doctor'],
                                capture_output=True, text=True, env=os.environ.copy(), timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)['target']['name'], 'Work')
        self.assertFalse(self.cache.exists())

    def test_listing_handles_replaced_symlink_and_malformed_identity(self):
        self.register()
        self.register(self.work, 'Work')
        renamed = self.base / 'renamed'
        self.personal.rename(renamed)
        self.personal.symlink_to(renamed, target_is_directory=True)
        (self.work / '.orbit/vault.json').write_text('{"id": 42}')
        result = registry.list_orbits()
        self.assertEqual([entry['status'] for entry in result['orbits']], ['unavailable', 'unavailable'])
        self.assertFalse(self.cache.exists())

    def test_names_paths_identities_and_overlap_refuse_before_initialization(self):
        self.register()
        for root, name in [(self.work, 'Personal'), (self.personal, 'personal'), (self.personal, 'Other'),
                           (self.personal / 'nested', 'Nested'), (self.base, 'Parent')]:
            with self.subTest(root=root, name=name), self.assertRaises(orbit.OrbitError):
                self.register(root, name)
        for name in ['', ' ', ' bad', 'bad\nname', 'bad\x7fname', 'x' * 81]:
            with self.subTest(name=name), self.assertRaises(orbit.OrbitError):
                self.register(self.work, name)
        shutil.copytree(self.personal, self.work)
        with self.assertRaisesRegex(orbit.OrbitError, 'identity'):
            self.register(self.work, 'Work')
        self.assertFalse(self.cache.exists())

    def test_idempotency_preserves_config_and_vault(self):
        self.register()
        raw = self.cfg.read_bytes()
        original = {str(p.relative_to(self.personal)): p.read_bytes() for p in self.personal.rglob('*') if p.is_file()}
        second = self.register()
        self.assertEqual(second['status'], 'unchanged')
        self.assertEqual(self.cfg.read_bytes(), raw)
        self.assertEqual(original, {str(p.relative_to(self.personal)): p.read_bytes() for p in self.personal.rglob('*') if p.is_file()})
        self.assertFalse(list(self.cfg.parent.glob('*.backup-*')))

    def test_selectors_ignore_ambient_paths_and_fail_closed(self):
        self.register()
        with patch.dict(os.environ, ORBIT_VAULT=str(self.work)):
            self.assertEqual(registry.resolve().name, 'Personal')
        self.register(self.work, 'Work')
        with patch.dict(os.environ, ORBIT_VAULT=str(self.personal)):
            with self.assertRaisesRegex(orbit.OrbitError, 'multiple'):
                registry.resolve()
        self.assertEqual(registry.resolve('personal').root, self.personal)
        self.assertEqual(registry.resolve(path=str(self.work)).name, 'Work')
        for args in [{'orbit': 'unknown'}, {'orbit': 'Work', 'vault': str(self.work)}, {}, {'vault': str(self.base / 'other')}]:
            with self.assertRaises(orbit.OrbitError):
                orbit.dispatch('index', args)
        self.assertFalse(self.cache.exists())

    def test_replaced_and_missing_vaults_list_without_cache_writes(self):
        self.register()
        self.register(self.work, 'Work')
        shutil.rmtree(self.personal)
        marker = self.work / '.orbit/vault.json'
        data = json.loads(marker.read_text())
        data['id'] = str(uuid.uuid4())
        marker.write_text(json.dumps(data))
        listed = orbit.dispatch('list', {})
        self.assertEqual([x['status'] for x in listed['orbits']], ['unavailable', 'unavailable'])
        for name in ['Personal', 'Work']:
            with self.assertRaises(orbit.OrbitError):
                orbit.dispatch('index', {'orbit': name})
        self.assertFalse(self.cache.exists())

    def test_unnamed_setup_cannot_overwrite_registry(self):
        self.register()
        raw = self.cfg.read_bytes()
        with self.assertRaises(orbit.OrbitError):
            orbit.dispatch('setup', {'path': str(self.work), 'create': True})
        self.assertFalse(self.work.exists())
        self.assertEqual(self.cfg.read_bytes(), raw)

    def test_unsupported_and_malformed_config_refuse(self):
        self.cfg.parent.mkdir()
        for data in [{'schema': 1, 'vault': str(self.personal)}, {'schema': 3}, {'schema': True}, {'schema': 2}, {'schema': 2, 'orbits': {'X': {}}},
                     {'schema': 2, 'orbits': {}, 'vault': str(self.personal)}]:
            self.cfg.write_text(json.dumps(data))
            with self.subTest(data=data), self.assertRaises(orbit.OrbitError):
                orbit.dispatch('list', {})

    def test_invalid_config_cannot_be_bypassed_with_explicit_path(self):
        orbit.initialize(str(self.personal), create=True)
        self.cfg.parent.mkdir()
        for raw in ('{invalid', '{"schema": 2}', '{"schema": 99}'):
            self.cfg.write_text(raw)
            with self.subTest(raw=raw), self.assertRaises(orbit.OrbitError):
                orbit.dispatch('doctor', {'vault': str(self.personal)})
            self.assertEqual(self.cfg.read_text(), raw)
            self.assertFalse(self.cache.exists())


class NamedMCPTest(unittest.TestCase):
    setUp = test_mcp.MCPTest.setUp
    run_server = test_mcp.MCPTest.run_server
    result = test_mcp.MCPTest.result

    def test_mcp_rename_contract_and_routed_save(self):
        listed = self.run_server([test_mcp.request(1, 'tools/list')])[0]['result']['tools']
        schema = next(tool['inputSchema'] for tool in listed if tool['name'] == 'orbit_rename')
        self.assertEqual(set(schema['required']), {'orbit', 'name'})
        self.assertEqual(set(schema['properties']), {'orbit', 'name'})
        self.result(self.run_server([call(1, 'setup', {'path': str(self.vault), 'name': 'Orbit', 'create': True})])[0])
        renamed = self.result(self.run_server([call(1, 'rename', {'orbit': 'Orbit', 'name': 'Work'})])[0])
        replies = self.run_server([call(1, 'apply', {'orbit': 'Work', 'plan': plan(content=note(body='Work routing receipt'))}),
                                   call(2, 'read', {'orbit': 'Work', 'path': 'Knowledge/Atlas.md'}),
                                   call(3, 'apply', {'orbit': 'Orbit', 'plan': plan()})])
        saved, read = map(self.result, replies[:2])
        for result in [saved, read]:
            self.assertEqual(result['target']['name'], 'Work')
            self.assertEqual(result['target']['path'], str(self.vault))
            self.assertEqual(result['target']['vault_id'], renamed['target']['vault_id'])
        self.assertIn('Work routing receipt', '\n'.join(line['text'] for line in read['lines']))
        self.assertTrue(replies[2]['result']['isError'])

    def test_concurrent_rename_and_registration_preserve_both(self):
        self.result(self.run_server([call(1, 'setup', {'path': str(self.vault), 'name': 'Orbit', 'create': True})])[0])
        messages = [call(1, 'rename', {'orbit': 'Orbit', 'name': 'Personal'}),
                    call(1, 'setup', {'path': str(self.base / 'work'), 'name': 'Work', 'create': True})]
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(lambda message: self.run_server([message])[0], messages))
        for result in results:
            self.result(result)
        names = {entry['name'] for entry in self.result(self.run_server([call(1, 'list')])[0])['orbits']}
        self.assertEqual(names, {'Personal', 'Work'})

    def test_concurrent_registration_preserves_both_entries(self):
        cfg = Path(self.env['ORBIT_CONFIG'])
        cfg.parent.mkdir(parents=True)
        cfg.write_text(json.dumps({'schema': 2, 'orbits': {}, 'custom': {'keep': True}, 'active': 'opaque', 'default': 'opaque'}))
        names = ['Personal', 'Work']
        def register(name):
            return self.run_server([call(1, 'setup', {'path': str(self.base / name), 'name': name, 'create': True})])[0]
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            responses = list(pool.map(register, names))
        for response in responses:
            self.result(response)
        data = json.loads(cfg.read_text())
        self.assertEqual(set(data['orbits']), set(names))
        self.assertEqual(data['custom'], {'keep': True})
        self.assertEqual(data['active'], 'opaque')
        self.assertEqual(data['default'], 'opaque')
        self.assertEqual(len(self.result(self.run_server([call(1, 'list')])[0])['orbits']), 2)

    def test_named_interleaved_and_parallel_processes(self):
        personal, work = self.base / 'personal', self.base / 'work'
        setup = self.run_server([call(1, 'setup', {'path': str(personal), 'name': 'Personal', 'create': True}),
                                 call(2, 'setup', {'path': str(work), 'name': 'Work', 'create': True})])
        for response in setup:
            self.result(response)
        contents = {'Personal': note(body='personal apricot family'), 'Work': note(body='work zephyr release')}
        writes = self.run_server([call(i, 'apply', {'orbit': name, 'plan': plan(content=content)})
                                  for i, (name, content) in enumerate(contents.items())])
        for response in writes:
            self.result(response)
        def check(name):
            responses = self.run_server([call(1, 'read', {'orbit': name, 'path': 'Knowledge/Atlas.md'}),
                                         call(2, 'search', {'orbit': name, 'query': 'apricot' if name == 'Personal' else 'zephyr'})])
            read, search = map(self.result, responses)
            self.assertEqual('\n'.join(line['text'] for line in read['lines']) + '\n', contents[name])
            self.assertEqual(read['target']['name'], name)
            self.assertEqual(search['target']['name'], name)
            self.assertEqual(search['results'][0]['path'], 'Knowledge/Atlas.md')
            return read['target']['vault_id']
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            ids = list(pool.map(check, ['Work', 'Personal']))
        self.assertNotEqual(*ids)
        responses = self.run_server([call(1, 'read', {'path': 'Knowledge/Atlas.md'}), call(2, 'list')])
        self.assertTrue(responses[0]['result']['isError'])
        self.assertEqual(len(self.result(responses[1])['orbits']), 2)
