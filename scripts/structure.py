"""Versioned Markdown schemas and the standard vault layout."""
from __future__ import annotations

from pathlib import Path
import re

DATA_FORMAT = 2
DIRECTORIES = ('Projects', 'Knowledge', 'People', 'Sources', 'Schemas', 'Maps')
TEMPLATES = Path(__file__).resolve().parents[1] / 'references' / 'schemas'


def bootstrap(root):
    import orbit
    existing_types = set()
    for path in sorted(orbit.safe(root, 'Schemas').glob('*.md')):
        text = orbit.safe(root, path.relative_to(root).as_posix()).read_text(encoding='utf-8-sig')
        kind = orbit.metadata(text).get('schema_for')
        if isinstance(kind, str):
            existing_types.add(kind)
    result = {}
    for path in sorted(TEMPLATES.glob('*.md')):
        text = path.read_text(encoding='utf-8')
        relative = f'Schemas/{path.name}'
        if not orbit.safe(root, relative).exists() and orbit.metadata(text)['schema_for'] not in existing_types:
            result[relative] = text
    return result


def _finding(path, schema, severity, message):
    return {'path': path, 'schema': schema, 'severity': severity, 'message': message}


def _definitions(root, notes):
    import orbit
    defaults = {f'Schemas/{p.name}': p.read_text(encoding='utf-8') for p in sorted(TEMPLATES.glob('*.md'))}
    custom = {}
    folder = orbit.safe(root, 'Schemas')
    if folder.exists():
        for path in sorted(folder.glob('*.md')):
            relative = path.relative_to(root).as_posix()
            custom[relative] = orbit.safe(root, relative).read_text(encoding='utf-8-sig')
    for note in notes:
        path = Path(note['path'])
        if path.parent.as_posix() == 'Schemas' and path.suffix.lower() == '.md':
            custom[note['path']] = note['text']
    definitions = {}
    findings = []
    custom_types = {}
    for path, text in custom.items():
        kind = orbit.metadata(text).get('schema_for')
        if isinstance(kind, str):
            custom_types.setdefault(kind, []).append(path)
    for kind, paths in custom_types.items():
        if len(paths) > 1:
            for path in paths:
                findings.append(_finding(path, path, 'error', f'Duplicate schema_for {kind}: {", ".join(sorted(paths))}'))
    for path, text in (defaults | custom).items():
        meta = orbit.metadata(text)
        kind = meta.get('schema_for')
        if path not in custom and isinstance(kind, str) and kind in custom_types:
            continue
        invalid = []
        for field in ('id', 'title', 'summary', 'schema_for'):
            if not isinstance(meta.get(field), str) or not meta[field].strip():
                invalid.append(f'{field} must be a nonempty string')
        if meta.get('type') != 'schema':
            invalid.append('type must be schema')
        version = meta.get('schema_version')
        if type(version) is not int or version < 1:
            invalid.append('schema_version must be a positive integer')
        if meta.get('validation') not in ('warn', 'strict'):
            invalid.append('validation must be warn or strict')
        for field in ('required_fields', 'required_sections'):
            value = meta.get(field)
            if not isinstance(value, list) or any(not isinstance(x, str) or not x.strip() for x in value):
                invalid.append(f'{field} must be a list of nonempty strings')
        lines = text.lstrip('\ufeff').splitlines()
        if not lines or lines[0] != '---' or '---' not in lines[1:]:
            invalid.append('schema must have closed frontmatter')
        if invalid:
            findings.extend(_finding(path, path, 'error', message) for message in invalid)
        elif len(custom_types.get(kind, [])) <= 1:
            definitions[kind] = {'path': path, **meta}
    return definitions, findings


def _headings(text):
    headings = set()
    fence = None
    for line in text.splitlines():
        marker = re.match(r'^\s{0,3}(`{3,}|~{3,})', line)
        if marker:
            if fence is None:
                fence = marker[1]
            elif marker[1][0] == fence[0] and len(marker[1]) >= len(fence):
                fence = None
            continue
        if fence is None:
            heading = re.match(r'^#{1,6}\s+(.+?)\s*#*$', line)
            if heading:
                headings.add(heading[1].strip().casefold())
    return headings


def schema_warnings(root, notes):
    definitions, findings = _definitions(root, notes)
    for note in notes:
        meta = note['meta']
        kind = meta.get('type')
        if not isinstance(kind, str) or kind not in definitions:
            continue
        schema = definitions[kind]
        severity = 'error' if schema['validation'] == 'strict' else 'warning'
        messages = []
        for field in schema['required_fields']:
            value = meta.get(field)
            if value is None or value == [] or isinstance(value, str) and not value.strip():
                messages.append(f'Missing required field: {field}')
        version = meta.get('schema_version')
        if version is not None and (type(version) is not int or version != schema['schema_version']):
            messages.append(f"schema_version must match {schema['schema_version']}")
        headings = _headings(note['text'])
        for section in schema['required_sections']:
            if section.casefold() not in headings:
                messages.append(f'Missing required section: {section}')
        findings.extend(_finding(note['path'], schema['path'], severity, message) for message in messages)
    return findings


def check(root, note_type=None):
    import orbit
    notes = orbit.scan(root)
    definitions, _ = _definitions(root, notes)
    findings = schema_warnings(root, notes)
    if note_type is not None:
        definitions = {kind: schema for kind, schema in definitions.items() if kind == note_type}
        paths = {note['path'] for note in notes if note['meta'].get('type') == note_type}
        findings = [f for f in findings if f['path'] in paths or f['path'] == f['schema']]
    return {'data_format': DATA_FORMAT, 'definitions': definitions, 'warnings': findings}
