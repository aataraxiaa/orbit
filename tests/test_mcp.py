import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import zipfile

from test_orbit import note, plan

ROOT = Path(__file__).resolve().parents[1]


def request(identifier, method, params=None):
    return {'jsonrpc': '2.0', 'id': identifier, 'method': method, 'params': params or {}}


def call(identifier, action, arguments=None):
    return request(identifier, 'tools/call', {'name': 'orbit_' + action, 'arguments': arguments or {}})


class MCPTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='orbit-mcp-')
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.vault = self.base / 'vault with spaces'
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(('ORBIT_', 'SECOND_BRAIN_'))}
        self.env.update(ORBIT_CONFIG=str(self.base / 'binding/config.json'), ORBIT_CACHE=str(self.base / 'cache'))

    def run_server(self, messages, command=None, cwd=None):
        result = subprocess.run(command or [sys.executable, str(ROOT / 'scripts/mcp_server.py')],
                                input='\n'.join(json.dumps(m) if not isinstance(m, str) else m for m in messages) + '\n',
                                capture_output=True, text=True, env=self.env, cwd=cwd or self.base, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, '')
        return [json.loads(line) for line in result.stdout.splitlines()]

    def result(self, response):
        self.assertNotIn('error', response)
        self.assertFalse(response['result']['isError'], response)
        return json.loads(response['result']['content'][0]['text'])

    def setup_vault(self):
        return self.result(self.run_server([call(1, 'setup', {'path': str(self.vault), 'create': True})])[0])

    def test_setup_save_search_read_and_restart_binding(self):
        setup = self.setup_vault()
        self.assertEqual(setup['vault'], str(self.vault))
        content = note(body='Staged rollout preserves rollback while migrations stay reversible.')
        responses = self.run_server([call(1, 'apply', {'plan': plan(content=content)}),
                                     call(2, 'search', {'query': 'rollback migrations'}),
                                     call(3, 'read', {'path': 'Knowledge/Atlas.md'})])
        self.assertEqual(self.result(responses[0])['status'], 'committed')
        self.assertEqual(self.result(responses[1])['results'][0]['path'], 'Knowledge/Atlas.md')
        saved = self.result(responses[2])
        self.assertEqual('\n'.join(line['text'] for line in saved['lines']) + '\n', content)
        restarted = self.run_server([call(1, 'doctor'), call(2, 'read', {'path': 'Knowledge/Atlas.md'})])
        self.assertEqual(self.result(restarted[0])['vault'], str(self.vault))
        self.assertEqual(self.result(restarted[1])['sha256'], saved['sha256'])
        updated = self.result(self.run_server([call(1, 'apply', {'plan': plan(content=content + '\nExtra user prose.\n', sha=saved['sha256'])})])[0])
        self.assertEqual(updated['status'], 'committed')
        conflict = self.run_server([call(1, 'apply', {'plan': plan(sha=saved['sha256'])})])[0]
        self.assertTrue(conflict['result']['isError'])
        self.assertIn('conflict', conflict['result']['content'][0]['text'])
        self.assertIn('Extra user prose.', (self.vault / 'Knowledge/Atlas.md').read_text())

    def test_protocol_and_invalid_requests_do_not_write(self):
        messages = [request(1, 'initialize', {'protocolVersion': 'future', 'capabilities': {}, 'clientInfo': {'name': 'test', 'version': '1'}}),
                    {'jsonrpc': '2.0', 'method': 'notifications/initialized'}, request(2, 'ping'), request(3, 'tools/list'),
                    call(4, 'setup', {'path': str(self.vault), 'create': 'true'}),
                    call(5, 'setup', {'path': 'relative', 'create': True}),
                    call(6, 'read', {'path': 'x.md', 'count': True}),
                    call(7, 'read', {'path': 'x.md', 'count': 501}),
                    call(8, 'doctor', {'command': 'arbitrary'}),
                    call(9, 'apply', {'plan': {'changes': [{'path': 'x.md', 'content': 'bad', 'reason': 'test'}]}}),
                    call(10, 'absent'), request(11, 'absent'), '{invalid', [],
                    request(12, 'initialize'), request(13, 'tools/call', {'name': ['bad']}),
                    {'jsonrpc': '2.0', 'id': 14, 'method': 'tools/call', 'params': []},
                    call(15, 'recover', {'operation': 'x', 'rollback': True, 'abandon': True})]
        responses = self.run_server(messages)
        self.assertEqual(responses[0]['result']['protocolVersion'], '2025-06-18')
        self.assertEqual(responses[1]['result'], {})
        tools = responses[2]['result']['tools']
        self.assertEqual(len(tools), 15)
        self.assertTrue(next(t for t in tools if t['name'] == 'orbit_apply')['annotations']['destructiveHint'])
        for response in responses[3:]:
            self.assertIn('error', response, response)
        self.assertFalse(self.vault.exists())
        self.assertFalse(Path(self.env['ORBIT_CONFIG']).exists())
        self.assertEqual(self.run_server(['{"jsonrpc":"2.0","id":NaN,"method":"ping"}'])[0]['error']['code'], -32700)

    def test_native_python3_launch_discovers_supported_runtime(self):
        responses = self.run_server([request(1, 'tools/list')], ['python3', str(ROOT / 'scripts/mcp_server.py')])
        self.assertEqual(len(responses[0]['result']['tools']), 15)

    def test_tool_discovery_accepts_common_metadata(self):
        responses = self.run_server([
            request(1, 'tools/list', {'_meta': {'progressToken': 'test'}, 'cursor': None}),
            request(2, 'tools/list', {'cursor': 'unknown-page'}),
        ])
        self.assertEqual(len(responses[0]['result']['tools']), 15)
        self.assertEqual(responses[1]['error']['code'], -32602)

    def test_operations_use_engine_validation_and_safe_paths(self):
        self.setup_vault()
        responses = self.run_server([call(1, 'read', {'path': '../outside.md'}),
                                     call(2, 'apply', {'plan': plan(content='Missing metadata')}),
                                     call(3, 'context', {'target': 'not present'}),
                                     call(4, 'index'), call(5, 'catalog'), call(6, 'relations'),
                                     call(7, 'maintain'), call(8, 'integration')])
        for response in responses[:3]:
            self.assertTrue(response['result']['isError'], response)
        for response in responses[3:]:
            self.result(response)
        source = self.base / 'source.txt'
        source.write_text('Selected original bytes')
        captured = self.result(self.run_server([call(1, 'capture', {'source': str(source)})])[0])
        self.assertEqual((self.vault / captured['path']).read_text(), source.read_text())
        records = self.result(self.run_server([call(1, 'integration')])[0])
        self.assertEqual(records['total'], 1)
        invalid = self.run_server([call(1, 'integration', {'record': {'source_sha256': captured['sha256'], 'expected_version': 1, 'stage': 'verified'}})])[0]
        self.assertTrue(invalid['result']['isError'])

    def test_versioned_migration_and_typed_schema_tools(self):
        self.setup_vault()
        marker = self.vault / '.orbit/vault.json'
        original_marker = json.loads(marker.read_text())
        self.assertEqual(original_marker['data_format'], 2)
        self.result(self.run_server([call(1, 'apply', {'plan': plan()})])[0])
        original_marker.pop('data_format')
        original_marker.pop('orbit_version')
        marker.write_text(json.dumps(original_marker))
        preview = self.result(self.run_server([call(1, 'migrate')])[0])
        self.assertEqual(preview['source_version'], 'unknown')
        migrated = self.result(self.run_server([call(1, 'migrate', {'action': 'apply', 'plan_id': preview['plan_id']})])[0])
        self.assertTrue(migrated['verified'])
        found = self.result(self.run_server([call(1, 'search', {'query': 'staged rollout', 'note_type': 'project'})])[0])
        self.assertEqual(found['results'][0]['path'], 'Projects/Atlas/Overview.md')
        schemas = self.result(self.run_server([call(1, 'schema', {'note_type': 'session'})])[0])
        self.assertIn('session', schemas['definitions'])
        self.assertEqual(self.result(self.run_server([call(1, 'migrate')])[0])['status'], 'unchanged')
        self.result(self.run_server([call(1, 'migrate', {'action': 'rollback', 'operation': migrated['operation']})])[0])
        self.assertTrue((self.vault / 'Knowledge/Atlas.md').exists())
        self.assertFalse((self.vault / 'Projects/Atlas/Overview.md').exists())

    def test_strict_schema_rejects_save_without_partial_changes(self):
        self.setup_vault()
        schema = self.vault / 'Schemas/Project.md'
        response = self.result(self.run_server([call(1, 'read', {'path': 'Schemas/Project.md'})])[0])
        changed = schema.read_text().replace('validation: "warn"', 'validation: "strict"')
        self.result(self.run_server([call(1, 'apply', {'plan': plan('Schemas/Project.md', changed, response['sha256'])})])[0])
        refused = self.run_server([call(1, 'apply', {'plan': plan()})])[0]
        self.assertTrue(refused['result']['isError'])
        self.assertIn('Schema validation failed', refused['result']['content'][0]['text'])
        self.assertFalse((self.vault / 'Knowledge/Atlas.md').exists())

    def test_packaged_transports_start_from_unrelated_directory(self):
        subprocess.run([sys.executable, str(ROOT / 'scripts/package.py')], check=True, capture_output=True)
        for archive_name in ('orbit-plugin.zip', 'orbit.mcpb'):
            with self.subTest(archive=archive_name):
                extracted = self.base / archive_name
                with zipfile.ZipFile(ROOT / 'dist' / archive_name) as archive:
                    archive.extractall(extracted)
                if archive_name.endswith('.mcpb'):
                    manifest = json.loads((extracted / 'manifest.json').read_text())
                    self.assertEqual(manifest['version'], '0.4.0')
                    transport = manifest['server']['mcp_config']
                    configurations = [(transport, '${__dirname}', None)]
                else:
                    configurations = []
                    for host, variable in (('.codex-plugin', None), ('.claude-plugin', '${CLAUDE_PLUGIN_ROOT}')):
                        manifest = json.loads((extracted / host / 'plugin.json').read_text())
                        transport = json.loads((extracted / manifest['mcpServers']).read_text())['mcpServers']['orbit']
                        if host == '.codex-plugin':
                            self.assertEqual(transport['cwd'], '.')
                            self.assertFalse(any('${' in arg for arg in transport['args']))
                        configurations.append((transport, variable, extracted / transport['cwd'] if 'cwd' in transport else None))
                for transport, variable, cwd in configurations:
                    self.assertEqual(transport['command'], 'python3')
                    args = [arg.replace(variable, str(extracted)) if variable else arg for arg in transport['args']]
                    responses = self.run_server([request(1, 'tools/list')], [sys.executable, *args], cwd)
                    self.assertEqual(len(responses[0]['result']['tools']), 15)


if __name__ == '__main__':
    unittest.main()
