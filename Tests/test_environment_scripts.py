import os
import select
import shlex
import shutil
import subprocess
import tempfile
import time
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ENVIRONMENT = ROOT / "scripts" / "lib" / "environment.sh"
UI_PREFLIGHT = ROOT / "scripts" / "lib" / "ui-test-preflight.sh"
BUILD_LOCK = ROOT / "scripts" / "with-build-lock.sh"


def make_full_xcode(app_path):
    developer = app_path / "Contents" / "Developer"
    (app_path / "Contents" / "Info.plist").parent.mkdir(parents=True, exist_ok=True)
    (app_path / "Contents" / "Info.plist").write_text("fixture", encoding="utf-8")
    (developer / "Platforms" / "MacOSX.platform" / "Developer" / "SDKs").mkdir(parents=True)
    xcodebuild = developer / "usr" / "bin" / "xcodebuild"
    xcodebuild.parent.mkdir(parents=True)
    xcodebuild.write_text("#!/bin/sh\nprintf 'Xcode 27.0\\nBuild version fixture\\n'\n", encoding="utf-8")
    xcodebuild.chmod(0o755)
    swift = developer / "usr" / "bin" / "swift"
    swift.write_text("#!/bin/sh\necho 'Apple Swift version 6.2 (fixture)'\n", encoding="utf-8")
    swift.chmod(0o755)
    return developer


def run_bash(script, environment):
    return subprocess.run(
        ["/bin/bash", "-c", script],
        cwd=str(ROOT),
        env=environment,
        text=True,
        capture_output=True,
        check=False,
    )


class EnvironmentScriptTests(unittest.TestCase):
    def test_explicit_valid_developer_dir_is_used(self):
        with tempfile.TemporaryDirectory() as temporary:
            developer = make_full_xcode(Path(temporary) / "Fixture Xcode.app")
            environment = os.environ.copy()
            environment["DEVELOPER_DIR"] = str(developer)
            script = (
                f"source {shlex.quote(str(ENVIRONMENT))}; "
                "ROOT=/fixture; sidecarbridge_resolve_developer_dir; "
                "printf '%s\\n' \"$DEVELOPER_DIR\""
            )
            result = run_bash(script, environment)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), str(developer))

    def test_invalid_explicit_developer_dir_fails_closed(self):
        environment = os.environ.copy()
        environment["DEVELOPER_DIR"] = "/fixture/not-an-xcode"
        script = (
            f"source {shlex.quote(str(ENVIRONMENT))}; "
            "ROOT=/fixture; sidecarbridge_resolve_developer_dir"
        )
        result = run_bash(script, environment)
        self.assertEqual(result.returncode, 2)
        self.assertIn("DEVELOPER_DIR is set but is not a usable full Xcode", result.stderr)

    def test_selected_xcode_swift_toolchain_is_reported(self):
        with tempfile.TemporaryDirectory() as temporary:
            temporary_path = Path(temporary)
            developer = make_full_xcode(temporary_path / "Fixture Xcode.app")
            xcrun = temporary_path / "bin" / "xcrun"
            xcrun.parent.mkdir()
            xcrun.write_text(
                f"#!/bin/sh\nif [[ \"$1\" == --find && \"$2\" == swift ]]; then echo {shlex.quote(str(developer / 'usr' / 'bin' / 'swift'))}; else exit 2; fi\n",
                encoding="utf-8",
            )
            xcrun.chmod(0o755)
            environment = os.environ.copy()
            environment["PATH"] = f"{xcrun.parent}:/usr/bin:/bin"
            script = (
                f"source {shlex.quote(str(ENVIRONMENT))}; "
                f"DEVELOPER_DIR={shlex.quote(str(developer))}; "
                "sidecarbridge_resolve_developer_dir; "
                "sidecarbridge_report_swift_toolchain"
            )
            result = run_bash(script, environment)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Swift: ", result.stdout)
        self.assertIn("Apple Swift version 6.2 (fixture)", result.stdout)

    def test_legacy_xcodegen_container_resolves_its_executable(self):
        with tempfile.TemporaryDirectory() as temporary:
            fixture_root = Path(temporary)
            executable = fixture_root / ".build" / "Tools" / "XcodeGen" / "xcodegen" / "bin" / "xcodegen"
            executable.parent.mkdir(parents=True)
            executable.write_text("#!/bin/sh\necho 'Version: 2.46.0'\n", encoding="utf-8")
            executable.chmod(0o755)
            environment = os.environ.copy()
            environment["PATH"] = "/usr/bin:/bin"
            script = (
                f"source {shlex.quote(str(ENVIRONMENT))}; "
                f"ROOT={shlex.quote(str(fixture_root))}; "
                "sidecarbridge_resolve_xcodegen; sidecarbridge_check_xcodegen_version; "
                "printf '%s|%s\\n' \"$XCODEGEN\" \"$XCODEGEN_VERSION\""
            )
            result = run_bash(script, environment)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), f"{executable}|2.46.0")

    def test_new_xcodegen_fallback_precedes_retained_legacy_copy(self):
        with tempfile.TemporaryDirectory() as temporary:
            fixture_root = Path(temporary)
            candidates = [
                fixture_root / ".tools" / "xcodegen" / "bin" / "xcodegen",
                fixture_root / ".build" / "Tools" / "XcodeGen" / "xcodegen" / "bin" / "xcodegen",
            ]
            for index, candidate in enumerate(candidates):
                candidate.parent.mkdir(parents=True)
                candidate.write_text(f"#!/bin/sh\necho {index}\n", encoding="utf-8")
                candidate.chmod(0o755)
            environment = os.environ.copy()
            environment["PATH"] = "/usr/bin:/bin"
            script = (
                f"source {shlex.quote(str(ENVIRONMENT))}; "
                f"ROOT={shlex.quote(str(fixture_root))}; "
                "sidecarbridge_resolve_xcodegen; printf '%s\\n' \"$XCODEGEN\""
            )
            result = run_bash(script, environment)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), str(candidates[0]))

    def test_xcodegen_archive_nesting_is_supported(self):
        with tempfile.TemporaryDirectory() as temporary:
            fixture_root = Path(temporary)
            executable = fixture_root / ".tools" / "xcodegen" / "xcodegen" / "bin" / "xcodegen"
            executable.parent.mkdir(parents=True)
            executable.write_text("#!/bin/sh\necho 'Version: 2.46.0'\n", encoding="utf-8")
            executable.chmod(0o755)
            environment = os.environ.copy()
            environment["PATH"] = "/usr/bin:/bin"
            script = (
                f"source {shlex.quote(str(ENVIRONMENT))}; "
                f"ROOT={shlex.quote(str(fixture_root))}; "
                "sidecarbridge_resolve_xcodegen; printf '%s\\n' \"$XCODEGEN\""
            )
            result = run_bash(script, environment)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), str(executable))

    def test_old_xcodegen_version_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            executable = Path(temporary) / "xcodegen"
            executable.write_text("#!/bin/sh\necho 'Version: 2.45.0'\n", encoding="utf-8")
            executable.chmod(0o755)
            environment = os.environ.copy()
            environment["PATH"] = "/usr/bin:/bin"
            script = (
                f"source {shlex.quote(str(ENVIRONMENT))}; "
                f"XCODEGEN={shlex.quote(str(executable))}; sidecarbridge_check_xcodegen_version"
            )
            result = run_bash(script, environment)
        self.assertEqual(result.returncode, 2)
        self.assertIn("XcodeGen 2.46.0 or newer is required; found 2.45.0", result.stderr)

    def test_noninteractive_ui_preflight_skips_with_reason(self):
        script = (
            f"source {shlex.quote(str(UI_PREFLIGHT))}; "
            "if sidecarbridge_ui_test_preflight; then exit 9; else exit 0; fi"
        )
        result = run_bash(script, os.environ.copy())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Viewer UI tests skipped:", result.stderr)
        self.assertNotIn("Viewer UI preflight ready", result.stderr)

    def test_build_entrypoints_keep_fork_and_upstream_flows_separate(self):
        fork_build = (ROOT / "scripts" / "build.sh").read_text(encoding="utf-8")
        upstream_build = (ROOT / "scripts" / "build-upstream.sh").read_text(encoding="utf-8")
        self.assertIn("-scheme SidecarBridgeMac", fork_build)
        self.assertIn("-scheme SidecarBridgeViewerMac", fork_build)
        self.assertNotIn("SidecarBridgePad", fork_build)
        self.assertIn("-scheme SidecarBridgePad", upstream_build)
        self.assertNotIn("/Volumes/D", fork_build + upstream_build)

    def test_help_does_not_create_build_state(self):
        entrypoints = (
            "build.sh",
            "build-upstream.sh",
            "ci-macos.sh",
            "generate-fork-project.sh",
            "release-macos.sh",
        )
        with tempfile.TemporaryDirectory() as temporary:
            fixture_root = Path(temporary)
            scripts_dir = fixture_root / "scripts"
            scripts_dir.mkdir()
            for name in entrypoints:
                shutil.copy2(ROOT / "scripts" / name, scripts_dir / name)
                result = subprocess.run(
                    [str(scripts_dir / name), "--help"],
                    cwd=str(fixture_root),
                    text=True,
                    capture_output=True,
                    check=False,
                )
                self.assertEqual(result.returncode, 0, f"{name}: {result.stderr}")
                self.assertFalse((fixture_root / ".build").exists(), name)

    @unittest.skipUnless(Path("/usr/bin/lockf").exists(), "macOS lockf is required")
    def test_build_lock_fails_fast_allows_nesting_and_releases_on_failure(self):
        with tempfile.TemporaryDirectory() as temporary:
            fixture_root = Path(temporary)
            scripts_dir = fixture_root / "scripts"
            scripts_dir.mkdir()
            wrapper = scripts_dir / "with-build-lock.sh"
            shutil.copy2(BUILD_LOCK, wrapper)
            lock_file = fixture_root / ".build" / "locks" / "mutations.lock"
            lock_file.parent.mkdir(parents=True)
            lock_file.touch()
            environment = os.environ.copy()
            environment.pop("SIDECARBRIDGE_BUILD_LOCK_ROOT", None)

            holder = subprocess.Popen(
                ["/usr/bin/lockf", "-k", str(lock_file), "/bin/sh", "-c", "echo lock-held; sleep 2"],
                cwd=str(fixture_root),
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            try:
                ready, _, _ = select.select([holder.stdout], [], [], 5)
                self.assertTrue(ready, "lock holder did not start")
                self.assertEqual(holder.stdout.readline().strip(), "lock-held")

                started = time.monotonic()
                contended = subprocess.run(
                    [str(wrapper), "/bin/true"],
                    cwd=str(fixture_root),
                    env=environment,
                    text=True,
                    capture_output=True,
                    check=False,
                    timeout=1.5,
                )
                elapsed = time.monotonic() - started
                self.assertNotEqual(contended.returncode, 0, contended.stdout)
                self.assertLess(elapsed, 1.5, "lock contention did not fail immediately")
            finally:
                if holder.poll() is None:
                    holder.terminate()
                holder.wait(timeout=5)
                holder.stdout.close()
                holder.stderr.close()

            failed = subprocess.run(
                [str(wrapper), "/bin/sh", "-c", "exit 23"],
                cwd=str(fixture_root),
                env=environment,
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(failed.returncode, 23, failed.stderr)

            nested_command = (
                f"exec {shlex.quote(str(wrapper))} /bin/sh -c 'printf nested-allowed'"
            )
            nested = subprocess.run(
                [str(wrapper), "/bin/sh", "-c", nested_command],
                cwd=str(fixture_root),
                env=environment,
                text=True,
                capture_output=True,
                check=False,
                timeout=5,
            )
            self.assertEqual(nested.returncode, 0, nested.stderr)
            self.assertEqual(nested.stdout, "nested-allowed")


if __name__ == "__main__":
    unittest.main()
