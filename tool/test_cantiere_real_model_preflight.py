import unittest
from tool.cantiere_real_model_preflight import (
    CAPABILITIES, MARKER, config_from_env, main,
)


def valid_env():
    return {
        "CANTIERE_ZERO_COST_ROUTES_VERIFIED": "YES",
        "CANTIERE_BROKER_URL": "https://example.invalid",
        "CANTIERE_CF_ACCESS_CLIENT_ID": "test-id",
        "CANTIERE_CF_ACCESS_CLIENT_SECRET": "test-secret",
    }


class ModelPreflightTest(unittest.TestCase):
    def test_denies_unapproved_cost(self):
        env = valid_env()
        del env["CANTIERE_ZERO_COST_ROUTES_VERIFIED"]
        with self.assertRaisesRegex(ValueError, "ZERO_COST_ROUTE"):
            config_from_env(env)

    def test_denies_insecure_or_credentialed_origin(self):
        for url in ("http://example.invalid", "https://u:p@example.invalid",
                    "https://example.invalid/something", "https://example.invalid/?a=1"):
            env = valid_env()
            env["CANTIERE_BROKER_URL"] = url
            with self.assertRaisesRegex(ValueError, "HTTPS_BROKER"):
                config_from_env(env)

    def test_requires_service_credentials(self):
        env = valid_env()
        del env["CANTIERE_CF_ACCESS_CLIENT_SECRET"]
        with self.assertRaisesRegex(ValueError, "SERVICE_CREDENTIALS"):
            config_from_env(env)

    def test_real_roles_mocked_contract_is_not_star_success(self):
        called = []
        def transport(origin, headers, path, payload=None):
            if path.endswith("/capabilities"):
                return {"capabilities": list(CAPABILITIES)}
            called.append(payload["capability"])
            return {"text": MARKER, "model": "synthetic-test-model"}
        self.assertEqual(len(main(valid_env(), transport)), 4)
        self.assertEqual(called, list(CAPABILITIES))

    def test_missing_capability_fails_closed(self):
        def transport(origin, headers, path, payload=None):
            return {"capabilities": ["orchestration"]}
        with self.assertRaisesRegex(ValueError, "FOUR_ROLE"):
            main(valid_env(), transport)

    def test_wrong_marker_fails_closed(self):
        def transport(origin, headers, path, payload=None):
            if path.endswith("/capabilities"):
                return {"capabilities": list(CAPABILITIES)}
            return {"text": "something else", "model": "synthetic-test-model"}
        with self.assertRaisesRegex(ValueError, "MARKER_MISMATCH"):
            main(valid_env(), transport)


if __name__ == "__main__":
    unittest.main()
