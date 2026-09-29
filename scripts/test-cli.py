#!/usr/bin/env python3
"""Exercise the actual agent interface, including separate-process locking."""
import concurrent.futures
import csv
import json
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
CLI = ROOT / '.build/debug/fieldwork-cli'

class AgentInterfaceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='fieldwork-cli-')
        self.workspace = pathlib.Path(self.temp.name) / 'Research with spaces'
        subprocess.run([str(CLI), 'init', str(self.workspace), '--sample'], check=True, capture_output=True, text=True)

    def tearDown(self):
        self.temp.cleanup()

    def command(self, *args, success=True):
        result = subprocess.run([str(CLI), *args, '--workspace', str(self.workspace)], text=True, capture_output=True)
        if success:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0)
        return result

    def show(self, record):
        return json.loads(self.command('show', record).stdout)

    def test_agent_completes_a_sequential_question(self):
        self.command('complete', 'ANS-001', success=False)  # Blocked by the replication task ahead of it.
        self.command('start', 'T-003', '--actor', 'agent-a')
        self.command('complete', 'T-003', '--actor', 'agent-a', success=False)
        result = json.loads(self.command('result', 'T-003', '--title', 'Replication comparison', '--summary', 'Gain reproduced.', '--details', 'Independent set: improvement persisted.', '--results', 'artifacts/replication.csv').stdout)
        self.command('metric', result['id'], 'gain_pp', '6.8')
        self.assertTrue(self.show(result['id'])['runID'].startswith('RUN-'))
        self.command('complete', 'T-003', '--actor', 'wrong-agent', success=False)
        self.command('complete', 'T-003', '--actor', 'agent-a')
        self.command('edit', 'ANS-001', '--summary', 'Reranking improved this evaluation.', '--details', 'Both pilot and replication showed an improvement.')
        self.command('complete', 'ANS-001')
        self.command('edit', 'C-001', '--summary', 'Supported within the tested settings.', '--details', 'Further domains remain untested.')
        self.command('complete', 'C-001')
        self.assertEqual(self.show('Q-001')['status'], 'complete')
        self.command('validate')

    def test_separate_agents_race_for_one_claim(self):
        def claim(index):
            return subprocess.run([str(CLI), 'start', 'T-004', '--actor', f'agent-{index}', '--workspace', str(self.workspace)], capture_output=True).returncode
        with concurrent.futures.ThreadPoolExecutor(max_workers=5) as pool:
            results = list(pool.map(claim, range(5)))
        self.assertEqual(results.count(0), 1)
        self.command('validate')

    def test_csv_multiline_content_survives_agent_edit(self):
        detail = 'Evidence, with "quotes".\nSecond line: 日本語 and α.\n'
        file = pathlib.Path(self.temp.name) / 'details.txt'
        file.write_text(detail)
        self.command('edit', 'Q-001', '--summary', 'Comma, quote " and unicode α', '--details-file', str(file))
        record = self.show('Q-001')
        self.assertEqual(record['detailedSummary'], detail)
        self.assertEqual(record['shortSummary'], 'Comma, quote " and unicode α')
        with (self.workspace / 'questions.csv').open(newline='') as f:
            stored = next(r for r in csv.DictReader(f) if r['id'] == 'Q-001')
        self.assertEqual(stored['detailed_summary'], detail)

    def test_move_step_within_question(self):
        def order():
            steps = json.loads(self.command('list', '--kind', 'task', '--question', 'Q-001', '--json').stdout)
            steps += json.loads(self.command('list', '--kind', 'answer', '--question', 'Q-001', '--json').stdout)
            steps += json.loads(self.command('list', '--kind', 'conclusion', '--question', 'Q-001', '--json').stdout)
            return [step['id'] for step in sorted(steps, key=lambda step: step['order'])]
        self.command('move', 'ANS-001', '--before', 'T-003')
        self.assertEqual(order(), ['T-001', 'T-002', 'ANS-001', 'T-003', 'C-001'])
        self.assertIn('ANS-001', [record['id'] for record in json.loads(self.command('ready').stdout)])
        self.command('move', 'T-003', '--last')
        self.assertEqual(order(), ['T-001', 'T-002', 'ANS-001', 'T-003', 'C-001'])  # Conclusions stay last.
        self.command('move', 'T-003', '--after', 'T-002')
        self.assertEqual(order(), ['T-001', 'T-002', 'T-003', 'ANS-001', 'C-001'])
        self.command('move', 'T-003', '--before', 'T-004', success=False)  # Another question.
        self.command('move', 'T-003', success=False)
        self.command('move', 'R-001', '--last', success=False)
        self.command('move', 'T-001', '--last')
        self.assertEqual(self.show('T-001')['status'], 'complete')  # Kept as an override below unfinished work.
        self.command('validate')

    def test_new_aim_and_standalone_question(self):
        aim = json.loads(self.command('add', 'aim', '--title', 'New topic').stdout)
        question = json.loads(self.command('add', 'question', '--parent', aim['id'], '--title', 'What is unknown?').stdout)
        task = json.loads(self.command('add', 'task', '--parent', question['id'], '--title', 'Inspect sources', '--summary', 'Collect evidence.').stdout)
        self.command('start', task['id'], '--actor', 'reader')
        self.command('result', task['id'], '--title', 'Initial findings', '--summary', 'Three relevant sources.')
        self.command('complete', task['id'], '--actor', 'reader')
        self.assertEqual(self.show(question['id'])['status'], 'active')  # Still needs an answer.
        self.command('link', question['id'], 'Q-001', 'inspired_by')
        newest = json.loads(self.command('add', 'question', '--parent', aim['id'], '--title', 'A later question').stdout)
        self.assertLess(newest['order'], self.show(question['id'])['order'])  # New questions lead the list.
        self.command('validate')

    def test_init_writes_the_agent_file_guide(self):
        guide = (self.workspace / 'AGENT_FILE_GUIDE.md').read_text()
        self.assertEqual(guide, (ROOT / 'AGENT_FILE_GUIDE.md').read_text())

    def test_checklist_status_and_rating(self):
        self.command('status', 'Q-002', 'working')
        self.assertEqual(self.show('Q-002')['status'], 'running')
        self.command('status', 'Q-002', 'done', '--actor', 'agent-a')
        self.assertEqual(self.show('Q-002')['status'], 'complete')
        self.command('status', 'Q-002', 'finished', success=False)
        self.command('rate', 'Q-002', 'up')
        self.assertEqual(json.loads(self.command('ratings').stdout), {'Q-002': 'up'})
        with (self.workspace / 'ratings.csv').open(newline='') as f:
            self.assertEqual(list(csv.DictReader(f)), [{'node_id': 'Q-002', 'rating': 'up'}])
        self.command('rate', 'Q-002', 'sideways', success=False)
        self.command('rate', 'missing', 'up', success=False)
        self.command('rate', 'Q-002', 'neutral')
        self.assertEqual(json.loads(self.command('ratings').stdout), {})
        self.command('status', 'Q-002', 'staged')
        self.assertEqual(self.show('Q-002')['status'], 'planned')
        self.command('validate')

if __name__ == '__main__':
    unittest.main(verbosity=2)
