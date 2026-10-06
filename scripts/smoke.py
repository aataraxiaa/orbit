#!/usr/bin/env python3
"""Exercise the CLI in an isolated temporary vault; never bind a personal vault."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

SCRIPT = Path(__file__).resolve().with_name('orbit.py')

def main():
    with tempfile.TemporaryDirectory(prefix='orbit-smoke-') as directory:
        root = Path(directory)
        env = dict(os.environ, ORBIT_CONFIG=str(root / 'config.json'), ORBIT_CACHE=str(root / 'cache'))
        env.pop('ORBIT_VAULT', None)
        env.pop('SECOND_BRAIN_VAULT', None)
        def run(*args):
            completed = subprocess.run([sys.executable, str(SCRIPT), *args], cwd=root,
                                       env=env, capture_output=True, text=True, timeout=15)
            if completed.returncode:
                raise RuntimeError(completed.stderr)
            return json.loads(completed.stdout)
        run('setup', str(root / 'Test Vault'), '--create')
        def note(id, title, body):
            fields = {'id': id, 'title': title, 'type': 'concept', 'summary': body.splitlines()[0]}
            return '---\n' + '\n'.join(f'{k}: {json.dumps(v)}' for k,v in fields.items()) + '\n---\n# ' + title + '\n\n' + body
        changes = [
            {'path': 'Knowledge/Atlas.md', 'reason': 'Save synthetic planning decision', 'expected_sha256': None,
             'content': note('demo-atlas', 'Atlas rollout', 'Use staged deployment to preserve rollback.\n\n## Connections\n- depends_on [[Knowledge/Migrations]] — migrations must remain reversible.\n')},
            {'path': 'Knowledge/Migrations.md', 'reason': 'Save reusable concept', 'expected_sha256': None,
             'content': note('demo-migrations', 'Database migrations', 'Reversible migrations allow staged releases.\n')}
        ]
        plan = root / 'plan.json'; plan.write_text(json.dumps({'changes': changes}), encoding='utf-8')
        receipt = run('apply', str(plan))
        assert receipt['verified']
        results = run('search', 'staged rollback')
        assert results['results'][0]['path'] == 'Knowledge/Atlas.md'
        assert run('context', 'Knowledge/Migrations')['total'] == 2
        assert run('read', 'Knowledge/Atlas.md')['sha256']
        assert not run('doctor')['issues']
        indexed = run('index')
        assert indexed['reparsed'] == 0
        assert run('catalog')['total'] == 2
        assert run('relations')['total'] == 1
        assert not run('maintain')['candidates']
        before = run('read', 'Knowledge/Atlas.md')['sha256']
        run('index', '--rebuild')
        assert run('read', 'Knowledge/Atlas.md')['sha256'] == before
        print('PASS: isolated setup → save two linked notes → search → backlinks → read → doctor')
        print('Temporary vault removed on exit. Your real vault and configuration were not changed.')

if __name__ == '__main__': main()
