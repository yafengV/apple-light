#!/usr/bin/env python3
"""Fail-closed report tests; real simulator assertions run separately."""
import copy
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

from verify_ios_counter import ROOT, TEST, counter_passed, fingerprints


class CounterReportTests(unittest.TestCase):
    def setUp(self):
        self.summary = {'result': 'Passed', 'totalTestCount': 1, 'passedTests': 1,
                        'failedTests': 0, 'skippedTests': 0, 'expectedFailures': 0}
        self.tree = {'testNodes': [{'nodeType': 'UI test bundle', 'children': [
            {'nodeType': 'Test Case', 'nodeIdentifier': TEST, 'result': 'Passed'}]}]}

    def test_exact_counter_can_pass(self):
        self.assertTrue(counter_passed(self.summary, self.tree))

    def test_zero_skipped_expected_and_failed_cannot_pass(self):
        for mutation in ({'totalTestCount': 0, 'passedTests': 0}, {'skippedTests': 1},
                         {'expectedFailures': 1}, {'failedTests': 1}, {'result': 'Failed'},
                         {'totalTestCount': 2, 'passedTests': 2}):
            with self.subTest(mutation=mutation):
                self.assertFalse(counter_passed(self.summary | mutation, self.tree))

    def test_missing_unknown_or_duplicate_counter_cannot_pass(self):
        self.assertFalse(counter_passed(self.summary, {}))
        for mutation in ({'nodeIdentifier': 'OtherTests/testUnrelated()'},
                         {'result': 'Skipped'}, {'result': 'Expected Failure'}):
            tree = copy.deepcopy(self.tree)
            tree['testNodes'][0]['children'][0].update(mutation)
            self.assertFalse(counter_passed(self.summary, tree))
        tree = copy.deepcopy(self.tree)
        tree['testNodes'][0]['children'] *= 2
        self.assertFalse(counter_passed(self.summary, tree))

    def test_missing_count_is_not_zero(self):
        for field in self.summary:
            summary = dict(self.summary)
            summary.pop(field)
            self.assertFalse(counter_passed(summary, self.tree), field)

    def test_source_edits_additions_and_test_edits_change_fingerprint(self):
        with tempfile.TemporaryDirectory() as root:
            project = Path(root)
            source, test = project / 'App.swift', project / 'UITests.swift'
            source.write_text('original')
            test.write_text('fixed assertions')
            before = fingerprints(project)
            source.write_text('changed')
            self.assertNotEqual(before, fingerprints(project))
            source.write_text('original')
            test.write_text('weakened assertions')
            self.assertNotEqual(before, fingerprints(project))
            test.write_text('fixed assertions')
            (project / 'New.swift').write_text('new implementation')
            self.assertNotEqual(before, fingerprints(project))

    def test_cli_rejects_weakened_fixed_test_before_running_xcode(self):
        with tempfile.TemporaryDirectory() as root:
            project, output = Path(root) / 'Project', Path(root) / 'Evidence'
            shutil.copytree(ROOT / 'fixtures/HelloShipiOS', project)
            (project / 'HelloShipiOSUITests.swift').write_text('import XCTest\n')
            result = subprocess.run([sys.executable, str(ROOT / 'script/verify_ios_counter.py'),
                                     '--project', str(project), '--simulator', 'not-a-device',
                                     '--output', str(output)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)
            self.assertIn('Fixed acceptance inputs must remain unchanged', result.stderr)
            self.assertFalse(output.exists())


if __name__ == '__main__':
    unittest.main()
