import unittest

from audit_android_permissions import (
    EXPECTED_PACKAGE,
    RECEIVER_PERMISSION,
    audit_permissions,
)


class AuditPermissionsTests(unittest.TestCase):
    def test_no_requests(self) -> None:
        self.assertEqual(audit_permissions(f"package: {EXPECTED_PACKAGE}\n"), [])

    def test_standard_flutter_internal_receiver_is_allowed(self) -> None:
        report = (
            f"package: {EXPECTED_PACKAGE}\n"
            f"permission: {RECEIVER_PERMISSION}\n"
            f"uses-permission: name='{RECEIVER_PERMISSION}'\n"
        )
        self.assertEqual(audit_permissions(report), [RECEIVER_PERMISSION])

    def test_never_allow_internet_or_sensitive_permissions(self) -> None:
        for permission in (
            "android.permission.INTERNET",
            "android.permission.CAMERA",
            "android.permission.READ_CONTACTS",
            "android.permission.ACCESS_FINE_LOCATION",
            "android.permission.RECORD_AUDIO",
        ):
            with self.subTest(permission=permission):
                report = f"package: {EXPECTED_PACKAGE}\nuses-permission: name='{permission}'\n"
                with self.assertRaisesRegex(ValueError, "Unexpected Android permission"):
                    audit_permissions(report)

    def test_unexpected_declaration_is_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "Unexpected custom permission"):
            audit_permissions(
                f"package: {EXPECTED_PACKAGE}\npermission: android.permission.INTERNET\n"
            )

    def test_unreviewed_implied_permissions_are_rejected(self) -> None:
        report = (
            f"package: {EXPECTED_PACKAGE}\n"
            f"uses-implied-permission: name='{RECEIVER_PERMISSION}'\n"
        )
        with self.assertRaisesRegex(ValueError, "implied permission"):
            audit_permissions(report)

    def test_truncated_report_or_wrong_identity_fails(self) -> None:
        with self.assertRaisesRegex(ValueError, "Missing or unexpected package"):
            audit_permissions(f"uses-permission: name='{RECEIVER_PERMISSION}'\n")
        with self.assertRaisesRegex(ValueError, "Unexpected application id"):
            audit_permissions(f"package: {EXPECTED_PACKAGE}\n", "org.other.score")

    def test_unrecognized_permission_syntax_fails(self) -> None:
        with self.assertRaisesRegex(ValueError, "Unrecognized permission"):
            audit_permissions(f"package: {EXPECTED_PACKAGE}\nuses-permission hacked\n")


if __name__ == "__main__":
    unittest.main()
