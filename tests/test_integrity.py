import json
import unittest
from unittest.mock import patch
import test_orbit as base
from test_orbit import note, plan, orbit


class IntegrityTest(unittest.TestCase):
    setUp = base.VaultTest.setUp
    tearDown = base.VaultTest.tearDown
    def test_missing_anchor_is_rejected(self):
        orbit.apply(self.root, plan())
        with self.assertRaises(orbit.OrbitError):
            orbit.apply(self.root, plan('Knowledge/Other.md',note('other','Other','[[Knowledge/Atlas#Missing]]')))
        orbit.apply(self.root, plan('Knowledge/Other.md',note('other','Other','[[Knowledge/Atlas#Atlas]]')))

    def test_captured_markdown_identity_cannot_block_save(self):
        orbit.apply(self.root, plan())
        orbit.capture(self.root, str(self.root/'Knowledge/Atlas.md'))
        orbit.apply(self.root, plan('Knowledge/Other.md',note('other','Other')))
        self.assertFalse(orbit.doctor(self.root)['issues'])

    def test_nested_unknown_metadata_is_preserved(self):
        original=note().replace('---\n# Atlas','custom:\n  keep: valuable\n---\n# Atlas')
        orbit.apply(self.root,plan(content=original))
        sha=orbit.read(self.root,'Knowledge/Atlas.md')['sha256']
        with self.assertRaises(orbit.OrbitError):
            orbit.apply(self.root,plan(content=original.replace('  keep: valuable\n',''),sha=sha))
        self.assertEqual((self.root/'Knowledge/Atlas.md').read_text(),original)

    def test_quoted_unknown_metadata_is_preserved(self):
        for field in ('"custom field"', '"custom:field"', "'custom field'"):
            with self.subTest(field=field):
                original=note().replace('---\n# Atlas',field+':\n  precious: value\n---\n# Atlas')
                target=self.root/'Knowledge/Atlas.md'
                target.parent.mkdir(exist_ok=True)
                target.write_text(original)
                sha=orbit.read(self.root,'Knowledge/Atlas.md')['sha256']
                with self.assertRaises(orbit.OrbitError):
                    orbit.apply(self.root,plan(content=note(),sha=sha))
                self.assertEqual(target.read_text(),original)

    def test_external_conflict_can_be_abandoned_without_losing_edit(self):
        orbit.apply(self.root,plan())
        sha=orbit.read(self.root,'Knowledge/Atlas.md')['sha256']
        target=self.root/'Knowledge/Atlas.md'
        original_atomic=orbit.atomic
        def interrupt(path,data):
            result=original_atomic(path,data)
            if path.parent.name=='operations' and json.loads(data)['status']=='prepared':
                target.write_text(target.read_text()+'\nExternal annotation\n')
            return result
        with patch.object(orbit,'atomic',interrupt),self.assertRaises(orbit.OrbitError):
            orbit.apply(self.root,plan(content=note(body='Updated'),sha=sha))
        operation=orbit.doctor(self.root)['pending_operations'][0]
        before=target.read_bytes()
        orbit.recover(self.root,operation,abandon=True)
        self.assertEqual(target.read_bytes(),before)
        orbit.apply(self.root,plan('Knowledge/Other.md',note('other','Other')))
        self.assertFalse(orbit.doctor(self.root)['pending_operations'])


if __name__=='__main__':unittest.main()
