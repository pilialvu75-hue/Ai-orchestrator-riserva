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
