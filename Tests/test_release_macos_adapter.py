import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "release-macos.sh"


class ReleaseMacOSAdapterTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = SCRIPT.read_text(encoding="utf-8")

    def test_xtrace_does_not_print_notary_environment(self):
        environment = os.environ.copy()
        environment.update({
            "MACOS_NOTARY_KEY_ID": "fixture-notary-key-id",
            "MACOS_NOTARY_ISSUER": "fixture-notary-issuer",
            "SIDECARBRIDGE_NOTARY_PROFILE": "fixture-notary-profile",
        })
        result = subprocess.run(
            ["bash", "-x", str(SCRIPT), "--help"],
            cwd=str(ROOT),
            env=environment,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("fixture-notary-key-id", result.stdout + result.stderr)
        self.assertNotIn("fixture-notary-issuer", result.stdout + result.stderr)
        self.assertNotIn("fixture-notary-profile", result.stdout + result.stderr)

    def test_explicit_identity_survives_security_lookup_failure(self):
        start = self.source.index("DEFAULT_SIGNING_IDENTITY=$(")
        end = self.source.index("\n\nif (( CHECK_ONLY ));", start)
        identity_block = self.source[start:end]
        with tempfile.TemporaryDirectory() as temporary:
            bin_dir = Path(temporary) / "bin"
            bin_dir.mkdir()
            security = bin_dir / "security"
            security.write_text("#!/bin/sh\nexit 17\n", encoding="utf-8")
            security.chmod(0o755)
            python = bin_dir / "python3"
            python.write_text(
                "#!/bin/sh\n"
                "[ \"$2\" = resolve-signing-identity ] || exit 20\n"
                "[ \"$3\" = --identity ] || exit 21\n"
                "[ \"$4\" = \"$SIDECARBRIDGE_SIGNING_IDENTITY\" ] || exit 22\n"
                "[ \"$#\" -eq 4 ] || exit 23\n"
                "printf '%s\\n' \"$4\"\n",
                encoding="utf-8",
            )
            python.chmod(0o755)
            environment = {
                "PATH": f"{bin_dir}:/usr/bin:/bin:/usr/sbin:/sbin",
                "NOTARIZATION_HELPER": "/fixture/macos_notarization.py",
                "PROJECT_CONFIG_PATH": "",
                "SIDECARBRIDGE_SIGNING_IDENTITY": "Developer ID Application: Test Fixture",
            }
            result = subprocess.run(
                ["bash", "-c", "set -euo pipefail\n" + identity_block + '\nprintf \'%s\\n\' "$SIGNING_IDENTITY"\n'],
                env=environment,
                text=True,
                capture_output=True,
                check=False,
            )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "Developer ID Application: Test Fixture")

    def test_sidecar_profile_environment_is_explicitly_mapped(self):
        auth_start = self.source.index("AUTH_ARGS=(resolve-auth")
        auth_end = self.source.index("\n\nDEVELOPER_DIR=", auth_start)
        auth_block = self.source[auth_start:auth_end]
        submit_start = self.source.index("  submit() {")
        submit_end = self.source.index("\n  read_submission_result()", submit_start)
        submit_block = self.source[submit_start:submit_end]
        with tempfile.TemporaryDirectory() as temporary:
            bin_dir = Path(temporary) / "bin"
            bin_dir.mkdir()
            python = bin_dir / "python3"
            python.write_text(
                "#!/bin/sh\n"
                "if [ \"$2\" = resolve-auth ]; then\n"
                "  shift 2\n"
                "  found=0\n"
                "  while [ $# -gt 0 ]; do\n"
                "    if [ \"$1\" = --profile ]; then\n"
                "      shift\n"
                "      [ \"$1\" = \"$SIDECARBRIDGE_NOTARY_PROFILE\" ] || exit 30\n"
                "      found=1\n"
                "    fi\n"
                "    shift\n"
                "  done\n"
                "  [ $found -eq 1 ] || exit 31\n"
                "  printf '%s\\n' keychain-profile\n"
                "elif [ \"$2\" = submit ]; then\n"
                "  shift 2\n"
                "  printf 'submit-args:'\n"
                "  printf ' <%s>' \"$@\"\n"
                "  printf '\\n'\n"
                "else\n"
                "  exit 32\n"
                "fi\n",
                encoding="utf-8",
            )
            python.chmod(0o755)
            script = (
                "set -euo pipefail\n"
                + auth_block
                + "\n"
                + submit_block
                + "\nsubmit /fixture/release.zip\n"
                + "printf 'auth-kind:%s\\n' \"$NOTARY_AUTH_MODE\"\n"
            )
            environment = {
                "PATH": f"{bin_dir}:/usr/bin:/bin:/usr/sbin:/sbin",
                "NOTARIZATION_HELPER": "/fixture/macos_notarization.py",
                "PROJECT_CONFIG_PATH": "",
                "ROOT": "/fixture/project",
                "SIDECARBRIDGE_NOTARY_PROFILE": "sidecar-profile-fixture",
            }
            result = subprocess.run(
                ["bash", "-c", script],
                env=environment,
                text=True,
                capture_output=True,
                check=False,
            )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("<--profile> <sidecar-profile-fixture>", result.stdout)
        self.assertIn("<--auth> <keychain-profile>", result.stdout)
        self.assertIn("auth-kind:keychain-profile", result.stdout)

    def test_build_and_test_children_do_not_inherit_notary_environment(self):
        match = re.search(r"(?m)^run_release_tool\(\) \{\n(.*?)^\}", self.source, re.DOTALL | re.MULTILINE)
        self.assertIsNotNone(match)
        function = "run_release_tool() {\n" + match.group(1) + "\n}"
        script = (
            "set -euo pipefail\n"
            + function
            + "\nrun_release_tool /bin/sh -c 'printf \"child:%s|%s|%s|%s|%s|%s\\n\" "
            + "\"${MACOS_NOTARY_PROFILE-}\" \"${MACOS_NOTARY_KEY_PATH-}\" "
            + "\"${MACOS_NOTARY_KEY_ID-}\" \"${MACOS_NOTARY_ISSUER-}\" "
            + "\"${SIDECARBRIDGE_NOTARY_PROFILE-}\" \"${SIDECARBRIDGE_RELEASE_CONFIG-}\"'\n"
            + "printf 'parent:%s\\n' \"$MACOS_NOTARY_KEY_ID\"\n"
        )
        environment = {
            "MACOS_NOTARY_PROFILE": "profile-fixture",
            "MACOS_NOTARY_KEY_PATH": "/fixture/key.p8",
            "MACOS_NOTARY_KEY_ID": "key-id-fixture",
            "MACOS_NOTARY_ISSUER": "issuer-fixture",
            "SIDECARBRIDGE_NOTARY_PROFILE": "sidecar-profile-fixture",
            "SIDECARBRIDGE_RELEASE_CONFIG": "/fixture/release.env",
        }
        result = subprocess.run(
            ["bash", "-c", script],
            env=environment,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ["child:|||||", "parent:key-id-fixture"])

    def test_submission_result_parser_filters_status_and_uuid(self):
        match = re.search(
            r'read_submission_result\(\) \{\n    python3 - "\$1" <<\'PY\'\n(.*?)\nPY\n  \}',
            self.source,
            re.DOTALL,
        )
        self.assertIsNotNone(match)
        sample = (
            "Apple submission status: Accepted\n"
            "Apple submission ID: 01234567-89ab-cdef-0123-456789abcdef\n"
            "Apple submission status: Accepted; untrusted suffix\n"
            "Apple submission ID: untrusted value\n"
        )
        result = subprocess.run(
            [sys.executable, "-", sample],
            input=match.group(1),
            text=True,
            capture_output=True,
            check=True,
        )
        self.assertEqual(
            json.loads(result.stdout),
            {"id": "01234567-89ab-cdef-0123-456789abcdef", "status": "Accepted"},
        )

    def test_failed_submit_retains_safe_id_and_status(self):
        start = self.source.index("  read_submission_result() {")
        end = self.source.index('\n  submit_and_record "$HOST_ZIP"', start)
        functions = self.source[start:end]
        script = (
            "set -euo pipefail\n"
            + functions
            + "\nsubmit() { printf '%s\\n' 'Apple submission status: Rejected' "
            + "'Apple submission ID: 01234567-89ab-cdef-0123-456789abcdef'; return 1; }\n"
            + "HOST_ZIP=/fixture/host.zip\nVIEWER_ZIP=/fixture/viewer.zip\n"
            + "HOST_NOTARY_ID=\"\"\nHOST_NOTARY_STATUS=not-submitted\n"
            + "if submit_and_record \"$HOST_ZIP\"; then exit 22; fi\n"
            + "printf 'record:%s|%s\\n' \"$HOST_NOTARY_ID\" \"$HOST_NOTARY_STATUS\"\n"
        )
        result = subprocess.run(
            ["bash", "-c", script],
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            result.stdout.splitlines()[-1],
            "record:01234567-89ab-cdef-0123-456789abcdef|Rejected",
        )


if __name__ == "__main__":
    unittest.main()
