"""Offline automation regression tests. No Codex, credentials, router or GUI."""
import importlib.util
import json
import os
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import check
import run_task


class AutomationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="biquad-automation-test-")
        self.root = Path(self.temporary.name)
        self.addCleanup(self.temporary.cleanup)

    def fixture_repo(self, automation_probe=False):
        root = self.root / "repo"
        root.mkdir()
        (root / "scripts").mkdir()
        (root / "Sources").mkdir()
        (root / "Sources/example.swift").write_text("// fixture\n")
        (root / ".gitignore").write_text("private/\n.build/\n")
        for name in ("check.py", "publication_check.py", "run_task.py"):
            (root / "scripts" / name).write_bytes((ROOT / "scripts" / name).read_bytes())
        if automation_probe:
            tests = root / "Tests/AutomationTests"
            tests.mkdir(parents=True)
            (tests / "test_imports.py").write_text(
                "import sys, unittest\nfrom pathlib import Path\n"
                "sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))\n"
                "import check, run_task\n"
                "class Probe(unittest.TestCase):\n"
                " def test_imports(self):\n"
                "  self.assertTrue(callable(check.default_gates) and callable(run_task.audit_scope))\n")
        def git(*args):
            return subprocess.check_output(["git", "-c", "core.hooksPath=/dev/null", *args], cwd=root, text=True, stderr=subprocess.DEVNULL).strip()
        git("init", "-q")
        git("add", ".gitignore", "Sources", "scripts", *(["Tests"] if automation_probe else []))
        git("-c", "user.name=Automation Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "commit", "-qm", "fixture")
        return root, git("rev-parse", "HEAD")

    def task_file(self, paths):
        path = self.root / "task.json"
        path.write_text(json.dumps({"id": "fixture-task", "approved": True, "goal": "Update only the fixture source", "allowedPaths": paths,
                                    "acceptance": "The fixture check must pass", "maxSeconds": 60}))
        return path

    def test_agent_command_uses_chatgpt_provider_without_user_overrides(self):
        command = run_task.agent_command(self.root, self.root / "schema.json", self.root / "result.json")
        self.assertEqual(command[:5], ["codex", "exec", "--ignore-user-config", "--model", "gpt-6-astra"])
        overrides = [command[index + 1] for index, value in enumerate(command) if value == "-c"]
        self.assertEqual(overrides, ['model_provider="openai"', 'forced_login_method="chatgpt"', 'approval_policy="never"'])
        self.assertEqual(command[command.index("--sandbox") + 1], "workspace-write")
        self.assertEqual(command[command.index("-C") + 1], str(self.root))
        self.assertNotIn("--ignore-rules", command)
        self.assertNotIn("--dangerously-bypass-approvals-and-sandbox", command)
        self.assertEqual(command[-1], "-")

    def test_explicit_model_selection_preserves_provider_and_sandbox(self):
        command = run_task.agent_command(self.root, "schema.json", "result.json", model="gpt-6-sol")
        self.assertEqual(command[command.index("--model") + 1], "gpt-6-sol")
        self.assertIn('model_provider="openai"', command)
        self.assertIn("workspace-write", command)
        for model in ("", "--oss", "bad model", None):
            with self.subTest(model=model), self.assertRaises(ValueError):
                run_task.agent_command(self.root, "schema.json", "result.json", model=model)

    def test_manifest_rejects_empty_nonstring_and_escaping_paths(self):
        for paths in ([""], [None], [42], [{}], ["."], ["Sources/../private"], ["/Sources"], ["Sources/\x00bad"]):
            with self.subTest(paths=paths), self.assertRaises(ValueError):
                run_task.load_task(self.task_file(paths))

    def test_manifest_normalizes_approved_paths(self):
        self.assertEqual(run_task.load_task(self.task_file(["Sources//", "Sources/"]))["allowedPaths"], ["Sources"])

    def test_manifest_rejects_nonobject_and_boolean_budget(self):
        path = self.task_file(["Sources"])
        task = json.loads(path.read_text())
        task["maxSeconds"] = True
        path.write_text(json.dumps(task))
        with self.assertRaises(ValueError):
            run_task.load_task(path)
        path.write_text("[]")
        with self.assertRaises(ValueError):
            run_task.load_task(path)

    def test_launch_error_replaces_old_pass_and_exposes_running_state(self):
        output = self.root / "evidence"
        output.mkdir()
        report = output / "result.json"
        report.write_text(json.dumps({"status": "PASS", "run": "old-run"}))
        def command(args, **kwargs):
            current = json.loads(report.read_text())
            self.assertEqual(current["status"], "RUNNING")
            self.assertNotEqual(current["run"], "old-run")
            if args[0] == "git":
                return subprocess.CompletedProcess(args, 0, "fixture-commit\n")
            raise FileNotFoundError("synthetic missing executable")
        with mock.patch.object(check, "run_command", side_effect=command):
            code = check.run_checks(self.root, evidence_dir=output, gates=[("missing-tool", ["not-a-command"], 1)])
        result = json.loads(report.read_text())
        self.assertEqual(code, 1)
        self.assertEqual(result["status"], "TEST_INVALID")
        self.assertEqual(result["gates"][0]["exitCode"], 127)

    def test_interrupt_finalizes_evidence_without_stale_pass(self):
        output = self.root / "evidence"
        def command(args, **kwargs):
            if args[0] == "git":
                return subprocess.CompletedProcess(args, 0, "fixture-commit\n")
            raise KeyboardInterrupt()
        with mock.patch.object(check, "run_command", side_effect=command):
            self.assertEqual(check.run_checks(self.root, evidence_dir=output, gates=[("interrupted", ["fixture"], 1)]), 1)
        result = json.loads((output / "result.json").read_text())
        self.assertEqual(result["status"], "INTERRUPTED")
        self.assertEqual(result["gates"][0]["exitCode"], 130)

    def descendant_command(self, pid_path):
        child = "import os,signal,time;from pathlib import Path;signal.signal(signal.SIGTERM,signal.SIG_IGN);Path(" + repr(str(pid_path)) + ").write_text(str(os.getpid()));time.sleep(30)"
        parent = "import subprocess,sys,time;subprocess.Popen([sys.executable,'-B','-c'," + repr(child) + "]);time.sleep(30)"
        return [sys.executable, "-B", "-c", parent]

    def assert_process_stopped(self, pid_path):
        self.assertTrue(pid_path.exists(), "The synthetic descendant did not start")
        pid = int(pid_path.read_text())
        for _ in range(100):
            result = subprocess.run(["ps", "-p", str(pid), "-o", "stat="], stdout=subprocess.PIPE, text=True)
            if result.returncode != 0 or not result.stdout.strip() or result.stdout.strip().startswith("Z"):
                return
            time.sleep(0.02)
        self.fail("Synthetic descendant survived process-group cleanup")

    def test_timeout_terminates_sigterm_ignoring_descendant(self):
        pid = self.root / "child.pid"
        with self.assertRaises(subprocess.TimeoutExpired):
            check.run_command(self.descendant_command(pid), cwd=self.root, timeout=0.6, stdout=subprocess.DEVNULL)
        self.assert_process_stopped(pid)

    def test_ctrl_c_terminates_descendant(self):
        pid = self.root / "child.pid"
        code = "import sys;sys.path.insert(0," + repr(str(ROOT / "scripts")) + ");import check\nwith check.interruption_signals():\n check.run_command(" + repr(self.descendant_command(pid)) + ",cwd=" + repr(str(self.root)) + ",timeout=30)\n"
        process = subprocess.Popen([sys.executable, "-B", "-c", code], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        try:
            deadline = time.monotonic() + 5
            while not pid.exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(pid.exists())
            process.send_signal(signal.SIGINT)
            process.wait(timeout=5)
            self.assertNotEqual(process.returncode, 0)
            self.assert_process_stopped(pid)
        finally:
            check.terminate_group(process)

    def test_harness_is_captured_from_commit_and_uses_trusted_publication(self):
        root, commit = self.fixture_repo()
        original = (root / "scripts/check.py").read_bytes()
        (root / "scripts/check.py").write_text("raise SystemExit(0)\n")
        destination = self.root / "trusted-harness"
        manifest = run_task.capture_harness(commit, destination, source_root=root)
        self.assertEqual((destination / "check.py").read_bytes(), original)
        (root / "scripts/publication_check.py").write_text("raise SystemExit(99)\n")
        spec = importlib.util.spec_from_file_location("captured_check", destination / "check.py")
        captured = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(captured)
        command = captured.default_gates(root, False)[0][1]
        self.assertEqual(Path(command[3]).resolve(), (destination / "publication_check.py").resolve())
        self.assertIn(str(root), command)
        result = check.run_command(command, cwd=root, timeout=10, stdout=subprocess.PIPE)
        self.assertEqual(result.returncode, 0, result.stdout)
        run_task.verify_harness(destination, manifest)

    def test_scope_rejects_ignored_writes_and_allows_build_output(self):
        root, commit = self.fixture_repo()
        (root / ".build").mkdir()
        (root / ".build/output").write_text("synthetic")
        self.assertEqual(run_task.audit_scope(root, commit, ["Sources"]), [])
        (root / "private").mkdir()
        (root / "private/unapproved.txt").write_text("synthetic")
        with self.assertRaisesRegex(ValueError, "exceeded"):
            run_task.audit_scope(root, commit, ["Sources"])

    def test_scope_rejects_environment_files_and_symlinks(self):
        root, commit = self.fixture_repo()
        environment = root / "Sources/.env.example"
        environment.write_text("fixture-placeholder")
        with self.assertRaisesRegex(ValueError, "Environment"):
            run_task.audit_scope(root, commit, ["Sources"])
        environment.unlink()
        (root / "Sources/link").symlink_to(self.root / "outside")
        with self.assertRaisesRegex(ValueError, "symlinks"):
            run_task.audit_scope(root, commit, ["Sources"])

    def test_nested_acceptance_timeout_terminates_its_gate_group(self):
        pid = self.root / "child.pid"
        inner = "import sys;sys.path.insert(0," + repr(str(ROOT / "scripts")) + ");import check\nwith check.interruption_signals():\n check.run_command(" + repr(self.descendant_command(pid)) + ",cwd=" + repr(str(self.root)) + ",timeout=30)\n"
        with self.assertRaises(subprocess.TimeoutExpired):
            check.run_command([sys.executable, "-B", "-c", inner], cwd=self.root, timeout=0.7,
                              stdout=subprocess.DEVNULL, cleanup_grace=5)
        self.assert_process_stopped(pid)

    def test_scope_rejects_symlinked_exempt_build_directory(self):
        root, commit = self.fixture_repo()
        (root / ".build").symlink_to(self.root / "outside")
        with self.assertRaisesRegex(ValueError, "symlinks"):
            run_task.audit_scope(root, commit, ["Sources"])

    def test_default_automation_gate_does_not_write_out_of_scope_bytecode(self):
        root, commit = self.fixture_repo(automation_probe=True)
        (root / "docs").mkdir()
        (root / "docs/note.md").write_text("An approved documentation change.\n")
        command = next(command for name, command, _ in check.default_gates(root, False) if name == "automation")
        result = check.run_command(command, cwd=root, timeout=15, stdout=subprocess.PIPE)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(list(root.rglob("__pycache__")), [])
        self.assertEqual(run_task.audit_scope(root, commit, ["docs"]), ["docs/note.md"])


if __name__ == "__main__":
    unittest.main()
