#!/usr/bin/env python3
"""Regression checks for release build ordering; uses only synthetic metadata."""

import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest


SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
CHECKER = SCRIPT_DIR / "check-release-build-number.py"


class ReleaseBuildNumberTests(unittest.TestCase):
    def check_build(self, metadata, tags):
        self.assertTrue(CHECKER.is_file(), "Release build-number validation is missing")
        with tempfile.TemporaryDirectory() as directory:
            version = pathlib.Path(directory) / "VERSION"
            history = pathlib.Path(directory) / "tags.txt"
            version.write_text(metadata)
            history.write_text(tags)
            return subprocess.run(
                [sys.executable, str(CHECKER), str(version), str(history)],
                text=True, capture_output=True,
            )

    def test_rejects_reused_build_after_marketing_version_increase(self):
        result = self.check_build(
            "INKLET_VERSION=1.1.8\nINKLET_BUILD_NUMBER=12\n", "v1.1.7-12\n"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must be greater than", result.stderr)

    def test_accepts_next_build_across_unordered_duplicate_release_and_git_tags(self):
        result = self.check_build(
            "INKLET_VERSION=1.1.9\nINKLET_BUILD_NUMBER=13\n",
            "v1.1.8-12\nv1.0.0-4\nv1.1.7-12\nv1.1.8-12\nnotes-only\n",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("1.1.9 (13)", result.stdout)

    def test_rejects_build_reset_even_after_major_version_increase(self):
        result = self.check_build(
            "INKLET_VERSION=2.0.0\nINKLET_BUILD_NUMBER=1\n", "v1.1.8-12\n"
        )
        self.assertNotEqual(result.returncode, 0)

    def test_includes_draft_tag_even_when_published_tag_is_older(self):
        result = self.check_build(
            "INKLET_VERSION=1.1.9\nINKLET_BUILD_NUMBER=13\n",
            "v1.0.0-4\nv1.2.0-14\n",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("14", result.stderr)

    def test_accepts_first_release_with_empty_history(self):
        result = self.check_build("INKLET_VERSION=1.0.0\nINKLET_BUILD_NUMBER=1\n", "")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_invalid_or_ambiguous_version_metadata(self):
        invalid = [
            "INKLET_VERSION=1.1.9\n", "INKLET_BUILD_NUMBER=13\n",
            "INKLET_VERSION=1.1\nINKLET_BUILD_NUMBER=13\n",
            "INKLET_VERSION=01.1.9\nINKLET_BUILD_NUMBER=13\n",
            "INKLET_VERSION=1.1.9\nINKLET_BUILD_NUMBER=0\n",
            "INKLET_VERSION=1.1.9\nINKLET_BUILD_NUMBER=013\n",
            "INKLET_VERSION=1.1.9\nINKLET_BUILD_NUMBER=-1\n",
            "INKLET_VERSION=1.1.9\nINKLET_BUILD_NUMBER=9223372036854775808\n",
            "INKLET_VERSION=1.1.9\nINKLET_BUILD_NUMBER=13\nINKLET_BUILD_NUMBER=12\n",
            "INKLET_VERSION=1.1.9\nINKLET_BUILD_NUMBER=$(echo 13)\n",
        ]
        for metadata in invalid:
            with self.subTest(metadata=metadata):
                result = self.check_build(metadata, "v1.1.8-12\n")
                self.assertNotEqual(result.returncode, 0)

    def test_fails_when_history_file_is_missing(self):
        self.assertTrue(CHECKER.is_file())
        with tempfile.TemporaryDirectory() as directory:
            version = pathlib.Path(directory) / "VERSION"
            version.write_text("INKLET_VERSION=1.1.9\nINKLET_BUILD_NUMBER=13\n")
            result = subprocess.run(
                [sys.executable, str(CHECKER), str(version), str(version.parent / "missing")],
                text=True, capture_output=True,
            )
            self.assertNotEqual(result.returncode, 0)


class ReleaseWorkflowTests(unittest.TestCase):
    def setUp(self):
        workflow_path = SCRIPT_DIR.parent / ".github/workflows/build-dmg.yml"
        result = subprocess.run(
            ["/usr/bin/ruby", "-ryaml", "-rjson", "-e",
             "puts JSON.generate(YAML.load_file(ARGV.fetch(0)))", str(workflow_path)],
            check=True, capture_output=True, text=True,
        )
        self.workflow = json.loads(result.stdout)
        self.steps = self.workflow["jobs"]["build-dmg"]["steps"]

    def test_serializes_release_jobs_across_branches(self):
        self.assertEqual(self.workflow.get("concurrency"), {
            "group": "inklet-dmg-release", "cancel-in-progress": False,
        })

    def test_checks_history_before_build_or_signing(self):
        names = [step.get("name") for step in self.steps]
        self.assertIn("Check release build number", names)
        guard_index = names.index("Check release build number")
        self.assertLess(guard_index, names.index("Resolve release metadata"))
        self.assertLess(guard_index, names.index("Import Developer ID certificate"))
        guard = self.steps[guard_index]
        self.assertEqual(guard["env"]["GH_TOKEN"], "${{ github.token }}")
        self.assertNotIn("test-release-build-number.py", guard["run"])

        for history_source in ("gh", "git"):
            for previous_build, fail_fetch in ((12, False), (14, False), (12, True)):
                with self.subTest(history_source=history_source, previous_build=previous_build, fail_fetch=fail_fetch):
                    with tempfile.TemporaryDirectory() as directory:
                        root = pathlib.Path(directory)
                        (root / "VERSION").write_text("INKLET_VERSION=1.1.9\nINKLET_BUILD_NUMBER=13\n")
                        (root / "scripts").symlink_to(SCRIPT_DIR)
                        for command in ("gh", "git"):
                            # A newer draft (gh) or Git-only tag must block this candidate.
                            tag = f"v1.2.0-{previous_build}" if command == history_source else "v1.0.0-4"
                            output = tag if command == "gh" else f"fixture refs/tags/{tag}"
                            required = '[[ "$*" == *"--paginate"* ]]' if command == "gh" else '[[ "$*" == *"--tags"* ]]'
                            stub = root / command
                            stub.write_text(
                                "#!/bin/bash\nset -euo pipefail\n" + required + "\n" +
                                ("exit 1\n" if fail_fetch and command == history_source
                                 else f"printf '%s\\n' '{output}'\n")
                            )
                            stub.chmod(0o755)
                        environment = dict(os.environ, PATH=f"{root}:{os.environ['PATH']}",
                                           RUNNER_TEMP=str(root), GITHUB_REPOSITORY="fixture/repo")
                        result = subprocess.run(
                            ["/bin/bash", "-c", guard["run"]], cwd=root, env=environment,
                            capture_output=True, text=True, timeout=15,
                        )
                        if not fail_fetch and previous_build < 13:
                            self.assertEqual(result.returncode, 0, result.stderr)
                        else:
                            self.assertNotEqual(result.returncode, 0)
                        if not fail_fetch and previous_build >= 13:
                            self.assertIn("must be greater than", result.stderr)


if __name__ == "__main__":
    unittest.main()
