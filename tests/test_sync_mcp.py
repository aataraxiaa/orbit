import shutil
import unittest
import uuid

import test_mcp
from test_mcp import call
from test_orbit import note, plan


class SyncMCPTest(unittest.TestCase):
    setUp = test_mcp.MCPTest.setUp
    run_server = test_mcp.MCPTest.run_server
    result = test_mcp.MCPTest.result
    setup_vault = test_mcp.MCPTest.setup_vault

    def tool(self, device, action, arguments=None):
        original = self.env
        self.env = self.devices[device]
        try:
            return self.result(self.run_server([call(1, action, arguments)])[0])
        finally:
            self.env = original

    def replicas(self, with_note=True):
        self.setup_vault()
        if with_note:
            self.result(self.run_server([call(1, 'apply', {'plan': plan()})])[0])
        self.other = self.base / 'other-machine' / 'orbit'
        shutil.copytree(self.vault, self.other)
        second = dict(self.env, ORBIT_CONFIG=str(self.base / 'other-config.json'),
                      ORBIT_CACHE=str(self.base / 'other-cache'), ORBIT_STATE=str(self.base / 'other-state'))
        self.devices = [self.env, second]
        self.tool(1, 'setup', {'path': str(self.other), 'name': 'Test'})

    def transfer(self):
        for source, target in ((self.vault, self.other), (self.other, self.vault)):
            for folder in ('commits', 'observations'):
                for path in (source / '.orbit' / folder).glob('*.json'):
                    destination = target / '.orbit' / folder / path.name
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    if destination.exists():
                        self.assertEqual(destination.read_bytes(), path.read_bytes())
                    else:
                        shutil.copyfile(path, destination)

    def test_conflict_inspect_resolve_and_retry_using_only_tools(self):
        self.replicas()
        path = 'Knowledge/Atlas.md'
        for device, body in enumerate(('Laptop decision.', 'Desktop decision.')):
            current = self.tool(device, 'read', {'path': path})
            self.tool(device, 'apply', {'plan': plan(content=note(body=body), sha=current['sha256'])})
        self.transfer()
        status = self.tool(0, 'sync')
        self.assertEqual(status['status'], 'conflicted')
        for alias in ('Knowledge/./Atlas.md', 'Knowledge//Atlas.md'):
            response = self.run_server([call(1, 'read', {'path': alias})])[0]
            self.assertTrue(response['result']['isError'])
        history = self.tool(0, 'sync', {'action': 'history', 'path': path})
        contents = [revision['content'] for revision in history['revisions']]
        self.assertTrue(any('Laptop decision.' in content for content in contents))
        self.assertTrue(any('Desktop decision.' in content for content in contents))
        self.assertNotIn(path, [row['path'] for row in self.tool(0, 'search', {'query': 'decision'})['results']])
        resolution = plan(content=note(body='Laptop and desktop decisions reviewed together.'),
                          sha=history['current']['sha256'])
        resolution['request_id'] = str(uuid.uuid4())
        resolution['changes'][0]['expected_heads'] = status['heads'][path]
        before = {p.relative_to(self.vault): p.read_bytes() for p in self.vault.rglob('*') if p.is_file()}
        self.assertEqual(self.tool(0, 'apply', {'plan': resolution, 'dry_run': True})['status'], 'preview')
        self.assertEqual(before, {p.relative_to(self.vault): p.read_bytes() for p in self.vault.rglob('*') if p.is_file()})
        receipt = self.tool(0, 'apply', {'plan': resolution})
        self.assertTrue(receipt['verified'])
        self.assertEqual(self.tool(0, 'apply', {'plan': resolution})['operation'], receipt['operation'])
        self.transfer()
        self.tool(1, 'sync')
        self.assertEqual(self.tool(0, 'read', {'path': path})['sha256'], self.tool(1, 'read', {'path': path})['sha256'])

    def test_collision_can_choose_identity_absent_from_local_markdown(self):
        self.replicas(with_note=False)
        path = 'Knowledge/Atlas.md'
        first = note('first', body='First independently created note.')
        second = note('second', body='Second independently created note.')
        self.tool(0, 'apply', {'plan': plan(content=first)})
        self.tool(1, 'apply', {'plan': plan(content=second)})
        self.transfer()
        status = self.tool(0, 'sync')
        history = self.tool(0, 'sync', {'action': 'history', 'path': path})
        resolution = plan(content=second, sha=history['current']['sha256'])
        resolution['changes'][0]['expected_heads'] = status['heads'][path]
        self.tool(0, 'apply', {'plan': resolution})
        self.transfer()
        self.tool(1, 'sync')
        self.assertEqual((self.vault / path).read_text(), second)
        self.assertEqual((self.other / path).read_text(), second)
        self.assertTrue(any(revision['content'] == first for revision in self.tool(0, 'sync', {'action': 'history', 'path': path})['revisions']))

    def test_same_identity_at_two_paths_resolves_to_one_location(self):
        self.replicas(with_note=False)
        first_path, second_path = 'Knowledge/First.md', 'Knowledge/Second.md'
        self.tool(0, 'apply', {'plan': plan(first_path, note('same', body='Laptop text.'))})
        self.tool(1, 'apply', {'plan': plan(second_path, note('same', body='Desktop text.'))})
        self.transfer()
        shutil.copyfile(self.other / second_path, self.vault / second_path)
        status = self.tool(0, 'sync')
        history = self.tool(0, 'sync', {'action': 'history', 'path': first_path})
        resolution = plan(first_path, note('same', body='Reviewed text.'), history['current']['sha256'])
        resolution['changes'][0]['expected_heads'] = status['heads'][first_path]
        self.tool(0, 'apply', {'plan': resolution})
        self.transfer()
        self.tool(1, 'sync')
        for folder in (self.vault, self.other):
            self.assertFalse((folder / second_path).exists())
            self.assertIn('Reviewed text.', (folder / first_path).read_text())

    def test_rules_external_edit_can_be_explicitly_adopted(self):
        self.replicas()
        path = 'ORBIT.md'
        content = (self.vault / path).read_text() + '\nUser rule: preserve original citations.\n'
        (self.vault / path).write_text(content)
        status = self.tool(0, 'sync')
        history = self.tool(0, 'sync', {'action': 'history', 'path': path})
        adoption = plan(path, content, history['current']['sha256'])
        adoption['changes'][0].update(expected_heads=status['heads'][path],
                                     observations=[o['id'] for o in history['observations']])
        self.tool(0, 'apply', {'plan': adoption})
        self.transfer()
        self.tool(1, 'sync')
        self.assertEqual((self.other / path).read_text(), content)

    def test_conflicted_schema_cannot_define_contract_until_resolved(self):
        self.replicas()
        path = 'Schemas/Concept.md'
        original = (self.vault / path).read_text()
        for device, content in enumerate((original.replace('validation: "warn"', 'validation: "strict"'), original + '\nAlternate schema.\n')):
            current = self.tool(device, 'read', {'path': path})
            self.tool(device, 'apply', {'plan': plan(path, content, current['sha256'])})
        self.transfer()
        status = self.tool(0, 'sync')
        response = self.run_server([call(1, 'schema', {'note_type': 'concept'})])[0]
        self.assertTrue(response['result']['isError'])
        history = self.tool(0, 'sync', {'action': 'history', 'path': path})
        resolution = plan(path, original, history['current']['sha256'])
        resolution['changes'][0]['expected_heads'] = status['heads'][path]
        self.tool(0, 'apply', {'plan': resolution})
        self.assertEqual(self.tool(0, 'schema', {'note_type': 'concept'})['definitions']['concept']['validation'], 'warn')


if __name__ == '__main__':
    unittest.main()
