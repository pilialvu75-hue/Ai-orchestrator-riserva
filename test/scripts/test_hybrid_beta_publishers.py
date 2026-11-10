import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FLAG = "AIVEXUS_EXPERIMENTAL_HYBRID_CONSENT_QA"
ASSET = "HYBRID-BETA-RELEASE-ATTESTATION.txt"


def source(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


class HybridBetaPublishersContractTest(unittest.TestCase):
    def test_runtime_gate_remains_default_off(self):
        content = source("lib/app/runtime_bootstrap.dart")
        self.assertIn("AIVEXUS_EXPERIMENTAL_HYBRID_CONSENT_QA", content)
        self.assertIn("defaultValue: false", content)

    def test_android_has_explicit_off_by_default_beta_only_input(self):
        content = source(".github/workflows/build.yml")
        self.assertIn("hybrid_consent_beta:", content)
        self.assertIn("default: false", content)
        self.assertIn("if [[ \"$OWNER_OPT_IN\" == 'true' && \"$RELEASE_CHANNEL\" != 'beta' ]]", content)
        self.assertEqual(content.count("--dart-define=" + FLAG), 2)
        self.assertIn(ASSET, content)
        self.assertIn("steps.hybrid_gate.outputs.enabled", content)
        self.assertIn("if: github.event_name == 'workflow_dispatch'", content)

    def test_only_owner_can_request_explicit_hybrid_beta(self):
        workflow = source(".github/workflows/owner-beta-checkpoint.yml")
        self.assertIn("hybrid-beta-checkpoint", workflow)
        self.assertIn("hybrid_consent_beta='false'", workflow)
        self.assertIn("if [[ \"$requested_type\" == 'hybrid-beta-checkpoint' ]]", workflow)
        self.assertIn("github.actor == github.repository_owner", workflow)
        self.assertIn("github.event.comment.user.login == github.repository_owner", workflow)
        self.assertIn("github.event.issue.number == 1008", workflow)
        self.assertIn('sha="${BASH_REMATCH[2]}"', workflow)
        self.assertIn('if [[ "$sha" != "$main_sha" ]]', workflow)
        self.assertIn('-f hybrid_consent_beta="$hybrid_consent_beta"', workflow)
        self.assertEqual(workflow.count("gh workflow run build.yml"), 1)
        self.assertEqual(
            workflow.count("gh workflow run windows-release-publish.yml"), 1
        )
        self.assertIn("release_state\" == \"success\"", workflow)
        self.assertIn("main changed during Android release", workflow)
        self.assertIn('-f android_run_id="$release_run_id"', workflow)
        self.assertLess(
            workflow.index('if [[ "$release_state" == "success" ]]'),
            workflow.index("gh workflow run windows-release-publish.yml"),
        )
        self.assertIn("hybrid_consent_beta='false'", workflow)


    def test_internal_hybrid_prs_enable_android_qa_without_publishing(self):
        workflow = source(".github/workflows/assistant-android-source-validation.yml")
        self.assertIn("github.event_name == 'pull_request'", workflow)
        self.assertIn("github.event.pull_request.head.repo.full_name == github.repository",
                      workflow)
        self.assertIn("startsWith(github.head_ref, 'feat/hybrid-')", workflow)
        self.assertNotIn("github.event.pull_request.number == 977", workflow)
        self.assertIn("HYBRID_QA_OPT_IN", workflow)
        self.assertIn('--dart-define=AIVEXUS_EXPERIMENTAL_HYBRID_CONSENT_QA="$HYBRID_QA_OPT_IN"', workflow)
        self.assertIn("test/core/runtime/inference/hybrid_cloud_network_recovery_next_turn_test.dart",
                      workflow)
        self.assertNotIn("gh release upload", workflow)

    def test_internal_hybrid_qa_is_reusable_on_all_desktop_platforms(self):
        for path, job_count in (
            (".github/workflows/hybrid-consent-windows-qa.yml", 1),
            (".github/workflows/hybrid-consent-macos-linux-qa.yml", 2),
        ):
            with self.subTest(workflow=path):
                workflow = source(path)
                self.assertEqual(
                    workflow.count("startsWith(github.head_ref, 'feat/hybrid-')"),
                    job_count,
                )
                self.assertEqual(
                    workflow.count(
                        "github.event.pull_request.head.repo.full_name == github.repository"
                    ), job_count,
                )
                self.assertNotIn("github.event.pull_request.number == 977",
                                 workflow)
                self.assertIn("${{ github.event.pull_request.number }}",
                              workflow)
                self.assertEqual(workflow.count(
                    "test/core/runtime/inference/hybrid_cloud_network_recovery_next_turn_test.dart"
                ), job_count)
                self.assertNotIn("gh release upload", workflow)

    def test_sha_bound_checkpoint_ci_runs_on_every_main_push(self):
        # #948: The owner checkpoint waits for five workflow results on the
        # exact main SHA. A paths-filtered push leaves that check waiting
        # forever after merges that change only tests or UI assets.
        names = (
            (".github/workflows/assistant-shared-tests.yml", "Assistant Shared Tests"),
            (".github/workflows/windows-build.yml", "Build Windows Desktop"),
            (".github/workflows/linux-build.yml", "Build Linux Desktop"),
            (".github/workflows/macos-build.yml", "Build macOS Desktop"),
            (".github/workflows/web-build.yml", "Web Cantiere Build"),
        )
        for path, name in names:
            with self.subTest(workflow=path):
                workflow = source(path)
                self.assertIn(f"name: {name}", workflow)
                self.assertIn("\n  push:\n", workflow)
                push_block = workflow.split("\n  push:\n", 1)[1]
                push_block = push_block.split("\n  pull_request:", 1)[0]
                push_block = push_block.split("\n\npermissions:", 1)[0]
                self.assertIn("main", push_block)
                self.assertNotIn("\n    paths:", push_block)

    def test_linux_replay_requires_verified_android_manual_release(self):
        workflow = source('.github/workflows/linux-release-publish.yml')
        self.assertIn('  workflow_dispatch:', workflow)
        self.assertIn('android_run_id:', workflow)
        self.assertIn("github.ref == 'refs/heads/main'", workflow)
        self.assertIn('steps.android_source.outputs.source_sha', workflow)
        self.assertIn('steps.android_source.outputs.run_number', workflow)
        self.assertIn('.name == "Build & Release APK"', workflow)
        self.assertIn('.event == "workflow_dispatch"', workflow)
        self.assertIn('.conclusion == "success"', workflow)
        self.assertIn('Not an authorized successful Android release', workflow)
        self.assertIn('git/ref/tags/', workflow)
        self.assertIn('Release tag does not point to the authorized Android source commit', workflow)
        self.assertLess(workflow.index('Validate already authorized Android release'),
                        workflow.index('Checkout exact Android release commit'))
        self.assertLess(workflow.index('Resolve existing explicitly published release tag'),
                        workflow.index('Build coordinated Linux release'))

    def test_owner_desktop_replay_dispatches_all_three_verified_publishers(self):
        dispatcher = source('scripts/dispatch_authorized_desktop_replay.sh')
        contract = source('.github/workflows/authorized-desktop-replay.yml')
        self.assertIn('channel=desktop-replay', dispatcher)
        self.assertIn('.event == "workflow_dispatch"', dispatcher)
        self.assertIn('.conclusion == "success"', dispatcher)
        self.assertIn('git/ref/tags/', dispatcher)
        self.assertIn("github.actor == 'pilialvu75-hue'", contract)
        self.assertIn("github.ref == 'refs/heads/release-request/desktop'", contract)
        for platform in ('windows', 'macos', 'linux'):
            with self.subTest(platform=platform):
                command = 'gh workflow run ' + platform + '-release-publish.yml'
                self.assertIn(command, dispatcher)
                self.assertIn(command, contract)
        self.assertLess(dispatcher.index('Published Android APK asset missing'),
                        dispatcher.index('gh workflow run linux-release-publish.yml'))

    def test_desktop_publishers_verify_issued_manifest_before_build(self):
        for platform in ("windows", "macos", "linux"):
            with self.subTest(platform=platform):
                content = source(f".github/workflows/{platform}-release-publish.yml")
                self.assertIn("id: hybrid_gate", content)
                self.assertIn("scripts/hybrid_beta_release_manifest.py resolve", content)
                self.assertIn(ASSET, content)
                self.assertIn("steps.publish_tag.outputs.tag", content)
                self.assertEqual(content.count("--dart-define=" + FLAG), 1)
                self.assertIn("steps.hybrid_gate.outputs.enabled", content)
                self.assertLess(content.index("id: hybrid_gate"),
                                content.index(f"run: flutter build {platform} --release"))
                self.assertIn("github.event.workflow_run.event == 'workflow_dispatch'", content)


if __name__ == "__main__":
    unittest.main()
