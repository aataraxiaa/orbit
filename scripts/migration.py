"""Versioned, recoverable migrations of authoritative vault files."""
import json
import os
from pathlib import Path
import re
import uuid
from urllib.parse import quote, unquote, urlsplit

import orbit

TARGET = '0.4.1'
FORMAT = 2


def _marker(root):
    return orbit.internal(root) + '/vault.json'


def _read(root, path):
    p = orbit.safe(root, path)
    return p.read_bytes().decode('utf-8') if p.exists() else None


def _journals(root):
    directory = orbit.safe(root, orbit.internal(root) + '/migrations')
    return [(p, json.loads(orbit.safe(root, p.relative_to(root).as_posix()).read_bytes()))
            for p in sorted(directory.glob('*.json'))]


def status(root):
    marker = json.loads(_read(root, _marker(root)))
    return {'data_format': marker.get('data_format', 1),
            'source_version': marker.get('orbit_version', 'unknown'),
            'target_version': TARGET,
            'pending': [r['id'] for _, r in _journals(root) if r['status'] == 'prepared']}


def ensure_writable(root):
    state = status(root)
    release = state['source_version']
    if release != 'unknown':
        if not isinstance(release, str) or not re.fullmatch(r'\d+\.\d+\.\d+', release):
            raise orbit.OrbitError('Unsupported recorded Orbit release; inspect the vault version before writing')
        if tuple(map(int, release.split('.'))) > tuple(map(int, TARGET.split('.'))):
            raise orbit.OrbitError('Vault was written by a newer Orbit release; downgrade is unsupported')
    if type(state['data_format']) is not int or state['data_format'] not in (1, FORMAT):
        raise orbit.OrbitError('Unsupported vault data format; update Orbit before writing')
    if state['pending']:
        raise orbit.OrbitError('Resume or roll back the pending migration before writing')


def _ordinary_pending(root):
    folder = orbit.safe(root, orbit.internal(root) + '/operations')
    if any(json.loads(p.read_bytes()).get('status') == 'prepared' for p in folder.glob('*.json')):
        raise orbit.OrbitError('Recover the pending save operation before migrating')


def _segment(value):
    value = str(value).strip()
    if not value or value.startswith('.') or any(c in value for c in '/\\:\x00'):
        raise orbit.OrbitError('Unsafe project title: ' + value)
    return value


def _destinations(notes):
    projects = [n for n in notes if n['type'] == 'project']
    identities = orbit.identities(projects)
    for project in projects:
        name = project['meta'].get('project')
        if isinstance(name, str) and name.strip():
            identities[name.casefold()].add(project['path'])
    mapping = {}
    warnings = []
    for n in notes:
        old = n['path']
        kind = n['type']
        if old in ('ORBIT.md', 'SECOND_BRAIN.md') or not kind:
            mapping[old] = old
            if not kind and old not in ('ORBIT.md', 'SECOND_BRAIN.md'):
                warnings.append('Unclassified note preserved: ' + old)
        elif kind == 'project':
            mapping[old] = 'Projects/' + _segment(n['title']) + '/Overview.md'
        elif kind in ('decision', 'session'):
            project = orbit.strings(n['meta'].get('project'))
            if len(project) != 1:
                raise orbit.OrbitError('A decision/session needs one unambiguous project: ' + old)
            matches = orbit.resolve(project[0], identities)
            if not matches:
                raise orbit.OrbitError('No matching project for ' + old + ': ' + project[0])
            if len(matches) > 1:
                raise orbit.OrbitError('Ambiguous project for ' + old + ': ' + project[0] + ' matches ' + ', '.join(matches))
            owner = next(p for p in projects if p['path'] == matches[0])
            folder = 'Decisions' if kind == 'decision' else 'Sessions'
            mapping[old] = f"Projects/{_segment(owner['title'])}/{folder}/{Path(old).name}"
        else:
            folder = {'person': 'People', 'source': 'Sources', 'map': 'Maps', 'schema': 'Schemas'}.get(kind, 'Knowledge')
            mapping[old] = folder + '/' + Path(old).name
    return mapping, warnings


def _rewrite(text, old, new, mapping, identities):
    front = re.match(r'\ufeff?---\r?\n.*?\r?\n---(?:\r?\n|$)', text, re.S)
    metadata = front.group() if front else ''
    body = text[len(metadata):]
    def wiki(match):
        token = match.group(1)
        target = re.split(r'[|#]', token, maxsplit=1)[0].strip()
        if not target:
            return match.group()
        resolved = orbit.resolve(target, identities)
        if len(resolved) > 1:
            raise orbit.OrbitError('Ambiguous wikilink in ' + old + ': ' + target)
        if not resolved:
            return match.group()
        dest = mapping[resolved[0]]
        if dest == resolved[0]:
            return match.group()
        suffix = token[len(re.split(r'[|#]', token, maxsplit=1)[0]):]
        return '[[' + str(Path(dest).with_suffix('')) + suffix + ']]'

    def destination(raw):
        angle = raw.startswith('<') and raw.endswith('>')
        value = raw[1:-1] if angle else raw
        parsed = urlsplit(value)
        if parsed.scheme or parsed.netloc or not parsed.path or value.startswith('/'):
            return raw
        path = unquote(parsed.path)
        resolved = os.path.normpath(str(Path(old).parent / path))
        if resolved.startswith('../'):
            raise orbit.OrbitError('Link escapes vault in ' + old)
        extensionless = resolved not in mapping and resolved + '.md' in mapping
        dest = mapping.get(resolved + '.md' if extensionless else resolved, resolved)
        if extensionless:
            dest = str(Path(dest).with_suffix(''))
        relative = os.path.relpath(dest, Path(new).parent).replace(os.sep, '/')
        encoded = quote(relative, safe='/@-._~') if '%' in parsed.path or angle is False and ' ' in relative else relative
        result = encoded + ('?' + parsed.query if parsed.query else '') + ('#' + parsed.fragment if parsed.fragment else '')
        return '<' + result + '>' if angle else result

    link = re.compile(r'(!?\[[^\]\n]*\]\()(<[^>\n]+>|[^\s()]+)(\s+(?:"[^"\n]*"|\'[^\'\n]*\'))?(\))')
    reference = re.compile(r'^(\s{0,3}\[[^\]\n]+\]:\s*)(<[^>\n]+>|\S+)(.*)$', re.M)
    def transform(part):
        result = re.sub(r'\[\[([^\]\n]+)\]\]', wiki, part)
        result = link.sub(lambda m: m[1] + destination(m[2]) + (m[3] or '') + m[4], result)
        result = reference.sub(lambda m: m[1] + destination(m[2]) + m[3], result)
        leftovers = link.sub('', part)
        if '](' in leftovers:
            raise orbit.OrbitError('Unsupported Markdown link syntax in ' + old)
        if re.search(r'<(?:img|a)\b', part, re.I):
            raise orbit.OrbitError('HTML links need manual migration in ' + old)
        return result
    for source, destination_path in mapping.items():
        if source != destination_path and (source in metadata or '/' in source and str(Path(source).with_suffix('')) in metadata):
            raise orbit.OrbitError('Migration would invalidate preserved metadata paths in ' + old)
    if transform(metadata) != metadata:
        raise orbit.OrbitError('Migration would rewrite preserved metadata links in ' + old)
    parts = re.split(r'(`{3,}[^\n]*\n.*?^`{3,}[^\n]*$|~{3,}[^\n]*\n.*?^~{3,}[^\n]*$|`+[^`\n]*`+)', body, flags=re.M | re.S)
    return metadata + ''.join(part if i % 2 else transform(part) for i, part in enumerate(parts))


def _snapshot(root):
    result = {}
    state = orbit.internal(root)
    for base, dirs, files in os.walk(root, followlinks=False):
        dirs[:] = sorted(d for d in dirs if not d.startswith('.') or str(Path(base, d).relative_to(root)) == state)
        for directory in dirs:
            orbit.safe(root, Path(base, directory).relative_to(root).as_posix())
        for name in sorted(files):
            p = Path(base, name)
            rel = p.relative_to(root).as_posix()
            if rel == state + '/write.lock' or rel.startswith(state + '/migrations/'):
                continue
            orbit.safe(root, rel)
            result[rel] = orbit.digest(p.read_bytes())
    return result


def _prepare(root):
    import structure
    state = status(root)
    ensure_writable(root)
    _ordinary_pending(root)
    notes = orbit.scan(root)
    if state['data_format'] == FORMAT:
        missing = list(structure.bootstrap(root))
        if missing:
            raise orbit.OrbitError('Format 2 compatibility check failed: missing schemas: ' + ', '.join(missing))
        findings = structure.schema_warnings(root, notes)
        if any(f.get('severity') == 'error' for f in findings):
            raise orbit.OrbitError('Format 2 compatibility check failed: strict schema errors: ' + json.dumps(findings))
        return {'status': 'unchanged', **state, 'compatible': True,
                'warnings': [], 'schema_warnings': findings, 'changes': []}, []
    mapping, warnings = _destinations(notes)
    files = _snapshot(root)
    for directory in structure.DIRECTORIES:
        path = orbit.safe(root, directory)
        if path.exists() and not path.is_dir():
            raise orbit.OrbitError('Standard folder is occupied by a file: ' + directory)
    outputs = {}
    occupied = {p.casefold(): p for p in files}
    for old, new in mapping.items():
        orbit.safe(root, new)
        if new.casefold() in occupied and occupied[new.casefold()] != old:
            raise orbit.OrbitError('Migration destination already exists: ' + new)
        if new.casefold() in {p.casefold() for p in outputs}:
            raise orbit.OrbitError('Migration destination collision: ' + new)
        for parent in Path(new).parents:
            if str(parent) != '.' and str(parent).casefold() in occupied:
                raise orbit.OrbitError('Migration destination parent is a file: ' + str(parent))
        outputs[new] = old
    table = orbit.identities(notes)
    desired = {}
    for new, old in outputs.items():
        desired[new] = _rewrite(_read(root, old), old, new, mapping, table)
    for old, new in mapping.items():
        if old != new and old not in desired:
            desired[old] = None
    schema_types = {orbit.metadata(value).get('schema_for') for path, value in desired.items()
                    if value is not None and Path(path).parent.as_posix() == 'Schemas'}
    for path, value in structure.bootstrap(root).items():
        if path not in desired and not orbit.safe(root, path).exists() and orbit.metadata(value).get('schema_for') not in schema_types:
            desired[path] = value
    projected = []
    for path, value in desired.items():
        if value is None or not path.lower().endswith('.md'):
            continue
        meta = orbit.metadata(value)
        projected.append({'path': path, 'text': value, 'meta': meta, 'id': meta.get('id'),
                          'title': meta.get('title', Path(path).stem), 'aliases': orbit.strings(meta.get('aliases')),
                          'links': orbit.links(value)})
    errors = [f for f in structure.schema_warnings(root, projected) if f['severity'] == 'error']
    if errors:
        raise orbit.OrbitError('Migrated schema validation failed: ' + json.dumps(errors))
    duplicate_ids = [i for i in orbit.issues(projected, root) if i['kind'] == 'duplicate-id']
    if duplicate_ids:
        raise orbit.OrbitError('Migration would duplicate note identities: ' + json.dumps(duplicate_ids))
    movements = [{'from': old, 'to': new} for old, new in mapping.items() if old != new]
    for path in sorted(files):
        if not path.startswith(orbit.internal(root) + '/integrations/') or not path.endswith('.json'):
            continue
        record = json.loads(_read(root, path))
        affected = [n for role in ('notes', 'extraction') for n in record.get(role, [])
                    if n.get('path') in mapping and (mapping[n['path']] != n['path'] or desired.get(mapping[n['path']]) != _read(root, n['path']))]
        if affected:
            record.setdefault('errors', []).append('Migration changed evidence paths/content; previous verification is historical and requires re-verification')
            record['migration'] = {'target_version': TARGET, 'mapping': movements, 'previous_stage': record.get('stage'), 'verification_stale': True}
            desired[path] = orbit.encode(record).decode()
    marker_path = _marker(root)
    marker = json.loads(_read(root, marker_path))
    marker.update(data_format=FORMAT, orbit_version=TARGET)
    desired[marker_path] = orbit.encode(marker).decode()
    writes = [{'path': p, 'before': _read(root, p), 'after': value} for p, value in desired.items() if _read(root, p) != value]
    writes.sort(key=lambda w: (w['path'] == marker_path, w['after'] is None, w['path']))
    plan_id = orbit.digest(orbit.encode({'inputs': files, 'writes': writes, 'target_version': TARGET}))
    report = {'status': 'preview', **state, 'target_format': FORMAT, 'plan_id': plan_id,
              'moves': movements, 'warnings': warnings,
              'changes': [{'path': w['path'], 'action': 'delete' if w['after'] is None else 'create' if w['before'] is None else 'update'} for w in writes]}
    return report, writes


def _execute(root, record, journal, rollback=False):
    import structure
    for w in record['writes']:
        if _read(root, w['path']) not in (w['before'], w['after']):
            raise orbit.OrbitError('Migration recovery conflict: ' + w['path'])
    if not rollback:
        for directory in structure.DIRECTORIES:
            orbit.safe(root, directory).mkdir(parents=True, exist_ok=True)
    direction = 'rollback' if rollback else 'forward'
    if record['status'] != 'prepared' or record.get('direction', 'forward') != direction:
        record['status'] = 'prepared'
        record['direction'] = direction
        orbit.atomic(journal, orbit.encode(record))
    for w in sorted(record['writes'], key=lambda w: w['path'] == _marker(root)):
        if _read(root, w['path']) not in (w['before'], w['after']):
            raise orbit.OrbitError('Migration recovery conflict: ' + w['path'])
        value = w['before'] if rollback else w['after']
        path = orbit.safe(root, w['path'])
        if value is None:
            path.unlink(missing_ok=True)
        else:
            orbit.atomic(path, value.encode('utf-8'))
    for w in record['writes']:
        if _read(root, w['path']) != (w['before'] if rollback else w['after']):
            raise orbit.OrbitError('Migration verification conflict: ' + w['path'])
    record['status'] = 'rolled-back' if rollback else 'committed'
    orbit.atomic(journal, orbit.encode(record))
    return {'status': record['status'], 'operation': record['id'], 'backup': journal.relative_to(root).as_posix(), 'verified': True}


def migrate(root, action='plan', target_version=None, plan_id=None, operation=None):
    root = Path(root)
    if target_version not in (None, TARGET):
        raise orbit.OrbitError('Unsupported migration target; supported target is ' + TARGET)
    if action == 'status':
        return status(root)
    if action == 'plan':
        return _prepare(root)[0]
    if action not in ('apply', 'resume', 'rollback'):
        raise orbit.OrbitError('Unknown migration action')
    with orbit.lock(root):
        current_format = status(root)['data_format']
        if type(current_format) is not int or current_format not in (1, FORMAT):
            raise orbit.OrbitError('Unsupported vault data format; update Orbit before migration recovery')
        if action == 'apply':
            report, writes = _prepare(root)
            if report['status'] == 'unchanged':
                return report
            if not plan_id or plan_id != report['plan_id']:
                raise orbit.OrbitError('Migration preview is missing or stale; run plan again')
            opid = str(uuid.uuid4())
            journal = orbit.safe(root, orbit.internal(root) + '/migrations/' + opid + '.json')
            record = {'id': opid, 'kind': 'migration', 'status': 'prepared', 'created': orbit.now(),
                      'plan_id': plan_id, 'source_format': 1, 'target_format': FORMAT,
                      'writes': writes, 'backup_manifest': {w['path']: orbit.digest(w['before'].encode()) if w['before'] is not None else None for w in writes}}
            orbit.atomic(journal, orbit.encode(record))
            return _execute(root, record, journal)
        if not operation or not re.fullmatch(r'[a-f0-9-]{36}', operation):
            raise orbit.OrbitError('A valid migration operation id is required')
        journal = orbit.safe(root, orbit.internal(root) + '/migrations/' + operation + '.json')
        if not journal.exists():
            raise orbit.OrbitError('Migration operation not found')
        record = json.loads(journal.read_bytes())
        if record['status'] == 'rolled-back' and action == 'resume':
            raise orbit.OrbitError('Migration was rolled back; create a new plan')
        if any(r['id'] != operation and r['status'] == 'prepared' for _, r in _journals(root)):
            raise orbit.OrbitError('Another migration is pending')
        _ordinary_pending(root)
        return _execute(root, record, journal, action == 'rollback' or record.get('direction') == 'rollback')
