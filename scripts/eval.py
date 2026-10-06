#!/usr/bin/env python3
"""Evaluate labeled synthetic evidence retrieval, not LLM answer quality."""
import argparse
import importlib.util
import json
import math
import os
from pathlib import Path
import platform
import statistics
import tempfile
import time
import orbit

DATASET_VERSION = 'v2-independent-audit'


def corpus(root, count):
    topics = json.loads((Path(__file__).resolve().parents[1] / 'tests/fixtures/retrieval/topics.json').read_text())
    cases = []

    def write(path, title, body, project, status='current', aliases=()):
        fields = dict(id=path, title=title, type='reference', summary=body.splitlines()[0], project=project, status=status, aliases=list(aliases))
        p = root / path
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text('---\n' + '\n'.join(f'{k}: {json.dumps(v)}' for k, v in fields.items()) + '\n---\n# ' + title + '\n\n' + body + '\n')

    for topic in topics:
        name = topic['name']
        main, old, source = (f'{folder}/{name}.md' for folder in ('Knowledge', 'History', 'Sources'))
        write(main, name + ' decision', topic['decision'] + '\n\n## Implementation\n' + topic['symbol'] + ' implements this decision.\n\n## Evidence\n[[' + source[:-3] + ']]', name, aliases=[topic['terms']])
        write(old, name + ' previous decision', topic['old'], name, 'superseded')
        write(source, name + ' planning record', 'Planning transcript.\n\n' + '\n\n'.join(f'## Agenda {n}\nDiscussion of staffing, review windows and documentation ownership for {name}.' for n in range(15)) + '\n\n## Acceptance condition\n' + topic['detail'], name)
        write(f'Other/{name}.md', name + ' decision', 'A different project with the same short name. Its policy requires a manual approval for every change.\n\nTopics discussed: ' + topic['terms'], name + '-other')
        labels = {'symbol': {main: topic['symbol']}, 'paraphrase': {main: topic['decision']}, 'scope': {main: topic['decision']}, 'history': {old: topic['old']}, 'source': {source: topic['detail']}, 'multi': {main: topic['decision'], source: topic['detail']}}
        for split, questions in topic['questions'].items():
            for category, question in questions.items():
                query = topic['symbol'] + ' responsibilities' if split == 'development' and category == 'symbol' else question
                evidence = labels[category]
                cases.append(dict(id=name + '-' + split + '-' + category, category=category, query=query, paths=list(evidence), evidence=evidence, scope=None if category in ('symbol', 'paraphrase') else name, split=split))
    vocabulary = ['storage', 'identity', 'deployment', 'cache', 'source', 'conversation', 'permissions', 'search', 'payment', 'terminal']
    for i in range(max(0, count - len(list(root.rglob('*.md'))))):
        topic = vocabulary[i % len(vocabulary)]
        write(f'Archive/record-{i:05d}.md', f'{topic} review {i}', f'Team {i%97} reviewed {topic} during iteration {i}.\n\n## Outcome\nThe review recorded documentation updates and an owner rotation. It did not change the project policy.\n\n## Follow-up\nConfirm the review with group {i%23} before the next meeting.', f'archive-{i%97}')
    return cases


def score(case, result):
    rows = result['results'][:5]
    paths = [row['path'] for row in rows]
    ranks = {}
    for path, expected in case['evidence'].items():
        for rank, row in enumerate(rows, 1):
            text = '\n'.join(snippet['text'] for snippet in row.get('snippets', []))
            if row['path'] == path and expected in text:
                ranks[path] = rank
                break
    reciprocal = [1 / ranks[path] if path in ranks else 0 for path in case['paths']]
    return {'hit': all(path in paths for path in case['paths']), 'passage_hit': len(ranks) == len(case['paths']), 'reciprocal_rank': statistics.mean(reciprocal), 'evidence_ranks': ranks, 'returned_paths': paths}


def aggregate(entries):
    total = len(entries)
    durations = sorted(entry['seconds'] for entry in entries)
    return {'cases': total, 'errors': sum('error' in entry for entry in entries), 'path_hits': sum(entry['hit'] for entry in entries), 'passage_hits': sum(entry['passage_hit'] for entry in entries), 'evidence_recall_at_5': sum(entry['passage_hit'] for entry in entries) / total if total else None, 'mean_reciprocal_rank': statistics.mean(entry['reciprocal_rank'] for entry in entries) if total else None, 'p50_seconds': statistics.median(durations) if durations else None, 'p95_seconds': durations[max(0, math.ceil(.95 * total) - 1)] if total else None}


def run(size, baseline=None):
    with tempfile.TemporaryDirectory(prefix='orbit-eval-') as temp:
        base, root = Path(temp), Path(temp) / 'vault'
        previous = {key: os.environ.get(key) for key in ('ORBIT_CONFIG', 'ORBIT_CACHE', 'ORBIT_VAULT', 'SECOND_BRAIN_VAULT')}
        os.environ['ORBIT_CONFIG'] = str(base / 'config.json')
        os.environ['ORBIT_CACHE'] = str(base / 'cache')
        os.environ.pop('ORBIT_VAULT', None)
        os.environ.pop('SECOND_BRAIN_VAULT', None)
        try:
            orbit.setup(str(root), create=True)
            cases = corpus(root, size)
            variants = {'indexed': orbit.search}
            if baseline:
                spec = importlib.util.spec_from_file_location('baseline_orbit', baseline)
                module = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(module)
                variants = {'baseline': module.search, **variants}
            files = list(root.rglob('*.md'))
            report = {'dataset_version': DATASET_VERSION, 'requested_notes': size, 'notes': len(files), 'bytes': sum(path.stat().st_size for path in files), 'expected_cases': len(cases), 'expected_heldout_cases': sum(case['split'] == 'heldout' for case in cases), 'variants': {}}
            for label, search in variants.items():
                start = time.perf_counter()
                cold = {'query': 'RollbackCoordinator'}
                try:
                    cold['mode'] = search(root, cold['query'], 5)['mode']
                except Exception as error:
                    cold['error'] = str(error)
                cold['seconds'] = time.perf_counter() - start
                report['variants'][label] = {'cold_first_call': cold, 'cases': [], 'errors': []}
            for case in cases:
                for label, search in variants.items():
                    start = time.perf_counter()
                    entry = {**case, 'hit': False, 'passage_hit': False, 'reciprocal_rank': 0, 'evidence_ranks': {}, 'returned_paths': []}
                    try:
                        result = search(root, case['query'], 5, scope=case['scope']) if label == 'indexed' else search(root, case['query'], 5)
                        entry.update(score(case, result))
                        entry.update(output_bytes=len(json.dumps(result).encode()), mode=result['mode'])
                    except Exception as error:
                        entry['error'] = str(error)
                        report['variants'][label]['errors'].append({'case': case['id'], 'error': str(error)})
                    entry['seconds'] = time.perf_counter() - start
                    report['variants'][label]['cases'].append(entry)
            for variant in report['variants'].values():
                entries = variant['cases']
                variant['summary'] = aggregate(entries)
                variant['summary']['categories'] = {category: aggregate([entry for entry in entries if entry['category'] == category]) for category in sorted({case['category'] for case in cases})}
                variant['summary']['splits'] = {split: aggregate([entry for entry in entries if entry['split'] == split]) | {'categories': {category: aggregate([entry for entry in entries if entry['split'] == split and entry['category'] == category]) for category in sorted({case['category'] for case in cases})}} for split in ('development', 'heldout')}
            return report
        finally:
            for key, value in previous.items():
                if value is None:
                    os.environ.pop(key, None)
                else:
                    os.environ[key] = value


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sizes', nargs='+', type=int, default=[100, 1000, 10000])
    parser.add_argument('--baseline')
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    results = {'dataset_version': DATASET_VERSION, 'platform': platform.platform(), 'python': platform.python_version(), 'measurement': 'Synthetic helper evidence retrieval only; 60 development and 60 heldout questions. Heldout wording authored in a separate audit without production tuning; labels have not received independent human review. Multi-note reciprocal rank averages expected evidence ranks, counting missing evidence as zero. Cold first call reported separately; warm calls include freshness. Exceptions count as failures. Baseline has no native scope filter. No LLM answer or token measurements.', 'runs': [run(size, args.baseline) for size in args.sizes]}
    Path(args.output).write_text(json.dumps(results, indent=2))
    print(json.dumps([{'notes': run['notes'], 'variants': {label: variant['summary'] for label, variant in run['variants'].items()}} for run in results['runs']], indent=2))
