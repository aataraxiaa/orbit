"""Relocated native candidate checks. These do not establish desktop acceptance."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
BINARY = Path(os.environ.get('ORBIT_SWIFT_BINARY', str(ROOT / '.build/out/Products/Debug/orbit-mcp')))
BUNDLE = BINARY.parent / 'OrbitCore_OrbitCore.bundle'


@unittest.skipUnless(BINARY.is_file(), 'Build native package through MobileBuildMCP first')
class SwiftPackageTest(unittest.TestCase):
    def test_relocated_manifests_have_no_python_runtime_and_preserve_notes(self):
        with tempfile.TemporaryDirectory(prefix='orbit-native-package-') as temp:
            base = Path(temp).resolve()
            built = subprocess.run([sys.executable, str(ROOT / 'scripts/package_swift.py'),
                                    '--binary', str(BINARY), '--resources', str(BUNDLE),
                                    '--output', str(base / 'candidate')], capture_output=True, text=True)
            self.assertEqual(built.returncode, 0, built.stderr)
            with zipfile.ZipFile(base / 'candidate/orbit-swift-plugin.zip') as archive:
                self.assertFalse(any(name.endswith('.py') for name in archive.namelist()))
                archive.extractall(base / 'relocated')
            relocated = base / 'relocated'
            self.assertIn('does not require or bundle Python', (relocated / 'references/setup.md').read_text())
            self.assertIn('New Orbits use format 3', (relocated / 'skills/orbit-setup/SKILL.md').read_text())
            (relocated / 'bin/orbit-mcp').chmod(0o755)
            manifests = [json.loads((relocated / name).read_text())['mcpServers']['orbit']
                         for name in ('.mcp.json', '.codex.mcp.json')]
            manifests.append(json.loads((relocated / 'manifest.json').read_text())['server']['mcp_config'])
            env = dict(os.environ, ORBIT_CONFIG=str(base / 'config.json'),
                       ORBIT_CACHE=str(base / 'cache'), ORBIT_STATE=str(base / 'state'),
                       PATH='/usr/bin:/bin')
            def call(server, name, arguments):
                command = server['command'].replace('${CLAUDE_PLUGIN_ROOT}', str(relocated)).replace('${__dirname}', str(relocated))
                request = {'jsonrpc': '2.0', 'id': 1, 'method': 'tools/call',
                           'params': {'name': 'orbit_' + name, 'arguments': arguments}}
                result = subprocess.run([command, *server['args']], input=json.dumps(request)+'\n',
                                        cwd=relocated, env=env, capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)
                value = json.loads(result.stdout)['result']
                self.assertFalse(value['isError'], value)
                return json.loads(value['content'][0]['text'])
            target = base / 'folder'
            self.assertEqual(call(manifests[0], 'setup', {'name': 'Disposable', 'path': str(target), 'create': True})['status'], 'registered')
            content = '---\nid: packaged\ntitle: Packaged\ntype: concept\nsummary: Native persistence\n---\n# Packaged\nRelocated executable persists notes.\n'
            saved = call(manifests[1], 'apply', {'orbit': 'Disposable', 'plan': {
                'request_id': '99999999-9999-4999-8999-999999999999', 'changes': [{
                    'path': 'Knowledge/Packaged.md', 'content': content,
                    'reason': 'mechanical package acceptance', 'expected_sha256': None}]}})
            self.assertTrue(saved['verified'])
            # Each call starts a fresh native process. This is process persistence,
            # not a fresh conversation in an installed desktop host.
            read = call(manifests[2], 'read', {'orbit': 'Disposable', 'path': 'Knowledge/Packaged.md'})
            self.assertEqual(read['target']['name'], 'Disposable')
            self.assertEqual((target / 'Knowledge/Packaged.md').read_text(), content)
            self.assertTrue(call(manifests[2], 'search', {'orbit': 'Disposable', 'query': 'persistence'})['results'])

    def test_acceptance_launch_arguments_isolate_even_when_host_drops_env(self):
        with tempfile.TemporaryDirectory(prefix='orbit-native-isolation-') as temp:
            base = Path(temp).resolve()
            candidate = base / 'candidate'
            isolation = base / 'isolation'
            built = subprocess.run([sys.executable, str(ROOT / 'scripts/package_swift.py'),
                                    '--binary', str(BINARY), '--resources', str(BUNDLE),
                                    '--output', str(candidate), '--acceptance-root', str(isolation),
                                    '--candidate-version', '0.7.0-dev.1'],
                                   capture_output=True, text=True)
            self.assertEqual(built.returncode, 0, built.stderr)
            plugin = candidate / 'marketplace/plugins/orbit'
            configurations = [json.loads((plugin / name).read_text())['mcpServers']
                              for name in ('.mcp.json', '.codex.mcp.json')]
            for configuration in configurations:
                self.assertEqual(list(configuration), ['orbit-swift-acceptance'])
                self.assertNotIn('orbit', configuration)
            self.assertEqual(configurations[1]['orbit-swift-acceptance']['command'], '/usr/bin/env')
            self.assertEqual(configurations[1]['orbit-swift-acceptance']['args'][0], './bin/orbit-mcp')
            self.assertEqual(json.loads((plugin / '.codex-plugin/plugin.json').read_text())['version'], '0.7.0-dev.1')
            manifests = [configuration['orbit-swift-acceptance'] for configuration in configurations]
            manifests.append(json.loads((plugin / 'manifest.json').read_text())['server']['mcp_config'])
            env = dict(os.environ, ORBIT_CONFIG=str(base / 'ambient/config.json'),
                       ORBIT_CACHE=str(base / 'ambient/cache'), ORBIT_STATE=str(base / 'ambient/state'))
            for index, server in enumerate(manifests):
                self.assertIn('--config', server['args'])
                command = server['command'].replace('${CLAUDE_PLUGIN_ROOT}', str(plugin)).replace('${__dirname}', str(plugin))
                arguments = {'name': 'Isolated', 'path': str(base / 'folder'), 'create': True}
                request = {'jsonrpc': '2.0', 'id': 1, 'method': 'tools/call',
                           'params': {'name': 'orbit_setup' if index == 0 else 'orbit_list',
                                      'arguments': arguments if index == 0 else {}}}
                result = subprocess.run([command, *server['args']], input=json.dumps(request)+'\n',
                                        cwd=plugin, env=env, capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)
                value = json.loads(result.stdout)['result']
                self.assertFalse(value['isError'], value)
            self.assertTrue((isolation / 'config.json').is_file())
            self.assertFalse((base / 'ambient').exists())

    def test_deep_request_is_parse_error_and_process_remains_available(self):
        # A sub-8MiB malformed request must not overflow the Swift stack.
        raw = '[' * 20000 + '0' + ']' * 20000 + '\n'
        raw += json.dumps({'jsonrpc': '2.0', 'id': 2, 'method': 'ping'}) + '\n'
        result = subprocess.run([str(BINARY)], input=raw, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        replies = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(replies[0]['error']['code'], -32700)
        self.assertEqual(replies[1], {'jsonrpc': '2.0', 'id': 2, 'result': {}})


if __name__ == '__main__':
    unittest.main()
