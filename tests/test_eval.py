import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import orbit
import eval as evaluation


class EvaluationTest(unittest.TestCase):
    def test_heldout_has_sixty_distinct_questions_and_labels_every_path(self):
        with tempfile.TemporaryDirectory() as directory:
            cases = evaluation.corpus(Path(directory), 100)
        heldout = [case for case in cases if case['split'] == 'heldout']
        self.assertEqual(len(heldout), 60)
        self.assertEqual(len({case['query'] for case in cases}), 120)
        for category in ('symbol', 'paraphrase', 'scope', 'history', 'source', 'multi'):
            self.assertEqual(sum(case['category'] == category for case in heldout), 10)
        for case in cases:
            self.assertEqual(set(case['paths']), set(case['evidence']))
            self.assertTrue(all(case['evidence'].values()))
        self.assertTrue(all('acceptance condition' not in case['query'].lower() for case in cases))

    def test_multi_requires_evidence_in_each_expected_path(self):
        case = {'paths': ['one.md', 'two.md'], 'evidence': {'one.md': 'First fact.', 'two.md': 'Second fact.'}}
        result = {'results': [{'path': 'one.md', 'snippets': [{'text': 'First fact.'}]}, {'path': 'two.md', 'snippets': [{'text': 'Unrelated paragraph.'}]}]}
        scored = evaluation.score(case, result)
        self.assertTrue(scored['hit'])
        self.assertFalse(scored['passage_hit'])
        self.assertEqual(scored['reciprocal_rank'], .5)
        result['results'][1]['snippets'][0]['text'] = 'Second fact.'
        self.assertTrue(evaluation.score(case, result)['passage_hit'])
        self.assertEqual(evaluation.score(case, result)['reciprocal_rank'], .75)

    def test_errors_remain_in_denominator_and_cold_is_separate(self):
        before = os.environ.get('ORBIT_CONFIG')
        with patch.object(orbit, 'search', side_effect=RuntimeError('simulated failure')):
            result = evaluation.run(100)
        summary = result['variants']['indexed']['summary']
        self.assertEqual(summary['cases'], 120)
        self.assertEqual(summary['errors'], 120)
        self.assertEqual(summary['splits']['heldout']['cases'], 60)
        self.assertEqual(summary['evidence_recall_at_5'], 0)
        self.assertEqual(summary['mean_reciprocal_rank'], 0)
        self.assertIn('error', result['variants']['indexed']['cold_first_call'])
        self.assertEqual(before, os.environ.get('ORBIT_CONFIG'))


if __name__ == '__main__': unittest.main()
