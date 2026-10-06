"""Navigation and durable source-integration state, independent of search caches."""
from __future__ import annotations
import json
import re

STAGES = ('captured', 'extracted', 'integrated', 'verified')


def catalog(root, scope=None, limit=50, offset=0):
    import orbit
    notes = [n for n in orbit.scan(root) if n['path'] not in ('ORBIT.md', 'SECOND_BRAIN.md') and not n['path'].startswith('Sources/assets/')]
    if scope:
        notes = [n for n in notes if scope in orbit.strings(n['meta'].get('project')) + orbit.strings(n['meta'].get('topics'))]
    notes.sort(key=lambda n: (n['type'] != 'map', n['title'].casefold(), n['path']))
    offset = max(0, offset)
    entries = [{k: n[k] for k in ('id', 'path', 'title', 'type', 'status')} | {'summary': str(n['meta'].get('summary', '')), 'project': n['meta'].get('project'), 'topics': orbit.strings(n['meta'].get('topics'))} for n in notes[offset:offset + max(1, min(limit, 200))]]
    markdown = '# Knowledge catalog\n\n' + '\n'.join(f"- [[{n['path']}|{n['title']}]] — {n['summary']}" for n in entries) + '\n'
    return {'total': len(notes), 'entries': entries, 'offset': offset, 'more': offset + len(entries) < len(notes), 'markdown': markdown, 'written': False}


def relations(root, target=None):
    import orbit
    notes = orbit.scan(root)
    table = orbit.identities(notes)
    selected = None
    if target:
        matches = orbit.resolve(target, table)
        if len(matches) != 1:
            raise orbit.OrbitError('Relation target must resolve uniquely')
        selected = matches[0]
    result = []
    pattern = re.compile(r'^\s*-\s+(supports|contradicts|supersedes|depends[-_]on|derived[-_]from|related[-_]to|relates_to|applies_to|part_of|learned_from|informed_by)\s+\[\[([^\]]+)\]\]\s*[—–-]\s*(?:(asserted|inferred):\s*)?(\S.*)$')
    for note in notes:
        fence = None
        section = ''
        for number, line in enumerate(note['text'].splitlines(), 1):
            marker = re.match(r'^\s*(`{3,}|~{3,})', line)
            if marker:
                if fence is None:
                    fence = marker[1][0]
                elif fence == marker[1][0]:
                    fence = None
                continue
            if fence:
                continue
            heading = re.match(r'^#{1,6}\s+(.+?)\s*#*$', line)
            if heading:
                section = heading[1].casefold()
            match = pattern.match(line)
            if not match:
                continue
            kind, link, basis, evidence = match.groups()
            basis = basis or ('inferred' if section == 'possible connections' and re.search(r'\binferred\b', evidence, re.I) else 'recorded')
            destinations = orbit.resolve(link.split('|')[0].split('#')[0].strip(), table)
            if selected and selected != note['path'] and selected not in destinations:
                continue
            result.append({'source': note['path'], 'target': destinations[0] if len(destinations) == 1 else None, 'link': link, 'type': kind, 'basis': basis, 'evidence': evidence, 'line': number, 'sha256': note['sha256'], 'resolution': 'resolved' if len(destinations) == 1 else 'ambiguous' if destinations else 'missing'})
    return {'relations': result, 'total': len(result), 'hint': 'Relations are recorded claims, not independently established facts.'}


def _record_path(root, sha):
    import orbit
    if not isinstance(sha, str) or not re.fullmatch('[0-9a-f]{64}', sha):
        raise orbit.OrbitError('source_sha256 must be a SHA-256 digest')
    return orbit.safe(root, orbit.internal(root) + '/integrations/' + sha + '.json')


def _source(root, record):
    import orbit
    path = record['source_path']
    if not path.startswith('Sources/assets/') or orbit.digest(orbit.safe(root, path).read_bytes()) != record['source_sha256']:
        raise orbit.OrbitError('Integration source is missing or changed')


def _validate_record(root, record, path):
    import orbit
    if not isinstance(record, dict) or record.get('schema') != 1 or record.get('stage') not in STAGES or type(record.get('version')) is not int or record['version'] < 1:
        raise orbit.OrbitError('Invalid integration schema, stage, or version')
    if _record_path(root, record.get('source_sha256')) != path:
        raise orbit.OrbitError('Integration source identity does not match filename')
    source = record.get('source_path')
    if not isinstance(source, str) or not source.startswith('Sources/assets/'):
        raise orbit.OrbitError('Invalid integration source path')
    orbit.safe(root, source)
    coverage = record.get('coverage')
    if not isinstance(coverage, dict) or coverage.get('status') not in ('unknown', 'full', 'partial') or not isinstance(coverage.get('description'), str):
        raise orbit.OrbitError('Invalid integration coverage')
    for key in ('deferred', 'errors'):
        if not isinstance(record.get(key), list) or any(not isinstance(item, str) for item in record[key]):
            raise orbit.OrbitError(key + ' must be a list of strings')
    for key in ('notes', 'extraction'):
        evidence = record.get(key, [])
        if not isinstance(evidence, list):
            raise orbit.OrbitError(key + ' must be a list of evidence records')
        for item in evidence:
            if not isinstance(item, dict) or not isinstance(item.get('path'), str) or not isinstance(item.get('sha256'), str) or not re.fullmatch('[0-9a-f]{64}', item['sha256']):
                raise orbit.OrbitError('Invalid ' + key + ' path or sha256')
            target = orbit.safe(root, item['path'])
            if target.suffix.lower() != '.md' or any(part.startswith('.') for part in target.relative_to(root).parts):
                raise orbit.OrbitError('Integration evidence must be public Markdown')
    operations = record.get('operations', [])
    if not isinstance(operations, list) or any(not isinstance(op, str) or not re.fullmatch('[a-f0-9-]{36}', op) for op in operations):
        raise orbit.OrbitError('Invalid integration operations')
    if not isinstance(record.get('verification'), list):
        raise orbit.OrbitError('Integration verification must be a list')
    return record


def _load_record(root, path):
    import orbit
    try:
        return _validate_record(root, json.loads(path.read_text()), path)
    except (OSError, ValueError, TypeError, KeyError) as error:
        raise orbit.OrbitError('Cannot read integration record ' + path.name + ': ' + str(error)) from error


def init_capture(root, receipt):
    import orbit
    path = _record_path(root, receipt['sha256'])
    with orbit.lock(root):
        if path.exists():
            record = _load_record(root, path)
            _source(root, record)
            return record
        record = {'schema': 1, 'source_sha256': receipt['sha256'], 'source_path': receipt['path'], 'version': 1, 'stage': 'captured', 'coverage': {'status': 'unknown', 'description': ''}, 'extraction': [], 'notes': [], 'operation': None, 'operations': [], 'verification': [], 'deferred': [], 'errors': [], 'updated': orbit.now()}
        _source(root, record)
        orbit.atomic(path, orbit.encode(record))
        return record


def integration(root, record=None):
    import orbit
    if record is None:
        folder = orbit.safe(root, orbit.internal(root) + '/integrations')
        records, errors = [], []
        for p in sorted(folder.glob('*.json')):
            try:
                entry = _load_record(root, orbit.safe(root, p.relative_to(root).as_posix()))
                records.append(entry)
            except (OSError, ValueError, TypeError, orbit.OrbitError) as error:
                errors.append({'kind': 'malformed-integration', 'path': p.relative_to(root).as_posix(), 'error': str(error)})
        return {'records': records, 'total': len(records), 'errors': errors}
    if not isinstance(record, dict):
        raise orbit.OrbitError('Integration update must be an object')
    path = _record_path(root, record.get('source_sha256'))
    allowed = {'source_sha256', 'expected_version', 'stage', 'coverage', 'extraction', 'notes', 'operation', 'operations', 'verification', 'deferred', 'errors'}
    if set(record) - allowed:
        raise orbit.OrbitError('Unknown integration update fields')
    with orbit.lock(root):
        if not path.exists():
            raise orbit.OrbitError('Capture the source before integration')
        current = _load_record(root, path)
        _source(root, current)
        updates = {key: value for key, value in record.items() if key not in ('source_sha256', 'expected_version')}
        unchanged = all(current.get(key) == value for key, value in updates.items())
        if not unchanged and record.get('expected_version') != current['version']:
            raise orbit.OrbitError('Integration version conflict; read the latest record')
        candidate = current | updates
        _validate_record(root, candidate, path)
        stage = candidate['stage']
        if stage not in STAGES or STAGES.index(stage) not in (STAGES.index(current['stage']), STAGES.index(current['stage']) + 1):
            raise orbit.OrbitError('Integration stages must advance one step at a time')
        for key in ('deferred', 'errors'):
            if not isinstance(candidate[key], list) or any(not isinstance(s, str) for s in candidate[key]):
                raise orbit.OrbitError(key + ' must be a list of strings')
        if stage != 'captured':
            coverage = candidate['coverage']
            if not isinstance(coverage, dict) or coverage.get('status') not in ('full', 'partial') or not isinstance(coverage.get('description'), str) or not coverage['description'].strip():
                raise orbit.OrbitError('Extraction needs full/partial coverage with an explanation')
        if stage != 'captured':
            extraction = candidate.get('extraction')
            if not isinstance(extraction, list) or not extraction:
                raise orbit.OrbitError('Extraction requires saved note path and sha256 evidence')
            for evidence in extraction:
                if not isinstance(evidence, dict) or not isinstance(evidence.get('path'), str) or not isinstance(evidence.get('sha256'), str) or orbit.read(root, evidence['path'], count=1)['sha256'] != evidence['sha256']:
                    raise orbit.OrbitError('Extraction evidence is invalid or changed')
        if stage in ('integrated', 'verified'):
            notes = candidate['notes']
            if not isinstance(notes, list) or not notes:
                raise orbit.OrbitError('Integration requires affected notes')
            operations = candidate.get('operations') or ([candidate['operation']] if candidate.get('operation') else [])
            if 'operation' in updates and 'operations' not in updates:
                operations = [updates['operation']]
            if not isinstance(operations, list) or not operations or any(not isinstance(op, str) or not re.fullmatch(r'[a-f0-9-]{36}', op) for op in operations):
                raise orbit.OrbitError('Integration requires committed operations')
            committed = {}
            for operation in operations:
                journal = json.loads(orbit.safe(root, orbit.internal(root) + '/operations/' + operation + '.json').read_text())
                if journal['status'] != 'committed':
                    raise orbit.OrbitError('Integration operation is not committed')
                committed.update({w['path']: orbit.digest(w['after'].encode()) for w in journal['writes']})
            candidate['operations'] = operations
            if any(not isinstance(note, dict) or not isinstance(note.get('path'), str) or not isinstance(note.get('sha256'), str) for note in notes):
                raise orbit.OrbitError('Affected notes require path and sha256')
            if len({note['path'] for note in notes}) != len(notes):
                raise orbit.OrbitError('Affected notes must be unique')
            for note in notes:
                live = orbit.read(root, note['path'], count=1)
                if live['sha256'] != note['sha256'] or committed.get(note['path']) != note['sha256']:
                    raise orbit.OrbitError('Integrated note does not match committed operation and live content')
        if stage == 'verified':
            checks = candidate['verification']
            if not isinstance(checks, list) or not checks:
                raise orbit.OrbitError('Verification requires recall queries and expected paths')
            verified = set()
            expected = {n['path'] for n in candidate['notes']}
            for check in checks:
                if not isinstance(check, dict) or not isinstance(check.get('query'), str) or not check['query'].strip() or not isinstance(check.get('paths'), list) or not check['paths'] or any(not isinstance(p, str) for p in check['paths']):
                    raise orbit.OrbitError('Verification needs a query and expected paths')
                found = {n['path'] for n in orbit.search(root, check['query'], limit=8)['results']}
                if not set(check['paths']).issubset(found & expected):
                    raise orbit.OrbitError('Recall verification did not find expected integrated notes')
                verified.update(check['paths'])
            if verified != expected:
                raise orbit.OrbitError('Recall verification must cover all affected notes')
        if unchanged:
            return current
        candidate['version'] += 1
        candidate['updated'] = orbit.now()
        orbit.atomic(path, orbit.encode(candidate))
        return candidate


def maintain(root, limit=20):
    import orbit
    notes = orbit.scan(root)
    flags = [dict(issue, priority=1) for issue in orbit.issues(notes, root)]
    for relation in relations(root)['relations']:
        if relation['resolution'] != 'resolved':
            flags.append({'kind': 'unresolved-relation', 'path': relation['source'], 'line': relation['line'], 'priority': 1})
    integrations = integration(root)
    flags.extend(dict(error, priority=1) for error in integrations['errors'])
    for record in integrations['records']:
        try:
            _source(root, record)
        except (orbit.OrbitError, OSError):
            flags.append({'kind': 'integration-source-changed', 'source_sha256': record['source_sha256'], 'priority': 1})
        if record['stage'] != 'verified' or record['coverage'].get('status') != 'full' or record['deferred'] or record['errors']:
            flags.append({'kind': 'incomplete-integration', 'source_sha256': record['source_sha256'], 'stage': record['stage'], 'coverage': record['coverage'], 'priority': 2})
        for role in ('notes', 'extraction'):
            for note in record.get(role, []):
                try:
                    changed = orbit.read(root, note['path'], count=1)['sha256'] != note['sha256']
                except (OSError, ValueError, orbit.OrbitError):
                    changed = True
                if changed:
                    flags.append({'kind': 'integration-evidence-changed', 'evidence_role': role, 'path': note['path'], 'source_sha256': record['source_sha256'], 'priority': 1})
    for note in notes:
        if note['meta'].get('repository') and not note['meta'].get('revision') and not note['meta'].get('observed'):
            flags.append({'kind': 'missing-code-provenance', 'path': note['path'], 'priority': 3})
    flags.sort(key=lambda flag: (flag['priority'], flag.get('path', ''), flag['kind']))
    return {'total': len(flags), 'candidates': flags[:max(1, min(limit, 100))], 'written': False, 'hint': 'Mechanical signals only. Repository freshness and contradictions require source inspection.'}
