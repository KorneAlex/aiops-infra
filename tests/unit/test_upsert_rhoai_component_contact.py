"""Tests for scripts/upsert_rhoai_component_contact.py."""

from __future__ import annotations

import unittest
from pathlib import Path
import sys

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(REPO_ROOT / "scripts"))

import upsert_rhoai_component_contact as upsert  # noqa: E402

FIXTURE = """# RHOAI component → Slack routing
#
# Fields:
#   slack_team_handle:  required Slack user-group handle
#   slack_team_channel: optional channel override

components:

  # ---------------------------------------------------------------------------
  # Fallback for components not listed below
  # ---------------------------------------------------------------------------
  default:
    slack_team_handle: openshift-ai-devtestops-ic

  # ---------------------------------------------------------------------------
  # ai-core-platform  (2 components)
  # ---------------------------------------------------------------------------
  odh-kube-auth-proxy:
    slack_team_handle: ai-core-platform
    slack_team_channel: forum-openshift-ai-operator
  odh-must-gather:
    slack_team_handle: ai-core-platform
    slack_team_channel: forum-openshift-ai-operator

  # ---------------------------------------------------------------------------
  # openshift-ai-dashboard  (1 component)
  # ---------------------------------------------------------------------------
  odh-dashboard:
    slack_team_handle: openshift-ai-dashboard

  # ---------------------------------------------------------------------------
  # openshift-ai-devtestops-ic  (2 components)
  # ---------------------------------------------------------------------------
  odh-aaa-ci:
    slack_team_handle: openshift-ai-devtestops-ic
  odh-zzz:
    slack_team_handle: openshift-ai-devtestops-ic
"""


class TestExtractKnownHandles(unittest.TestCase):
    def test_collects_handles(self):
        handles = upsert.extract_known_handles(FIXTURE)
        self.assertIn("ai-core-platform", handles)
        self.assertIn("openshift-ai-dashboard", handles)
        self.assertIn("openshift-ai-devtestops-ic", handles)


class TestUpsertExistingGroup(unittest.TestCase):
    def test_inserts_alphabetically_and_updates_count(self):
        result = upsert.upsert_component_contact(
            FIXTURE, "odh-lighthouse", "ai-core-platform"
        )
        self.assertEqual(result["status"], "added")
        text = result["text"]
        self.assertIn("# ai-core-platform  (3 components)", text)
        proxy = text.index("odh-kube-auth-proxy:")
        lighthouse = text.index("odh-lighthouse:")
        must_gather = text.index("odh-must-gather:")
        self.assertLess(proxy, lighthouse)
        self.assertLess(lighthouse, must_gather)
        self.assertIn("odh-lighthouse:\n    slack_team_handle: ai-core-platform\n", text)
        # Original groups still present
        self.assertIn("odh-dashboard:", text)
        self.assertIn("# openshift-ai-dashboard  (1 component)", text)

    def test_inserts_channel_when_provided(self):
        result = upsert.upsert_component_contact(
            FIXTURE,
            "odh-lighthouse",
            "ai-core-platform",
            slack_team_channel="forum-openshift-ai-operator",
        )
        self.assertIn(
            "odh-lighthouse:\n    slack_team_handle: ai-core-platform\n"
            "    slack_team_channel: forum-openshift-ai-operator\n",
            result["text"],
        )

    def test_already_present_same_values(self):
        result = upsert.upsert_component_contact(
            FIXTURE,
            "odh-kube-auth-proxy",
            "ai-core-platform",
            slack_team_channel="forum-openshift-ai-operator",
        )
        self.assertEqual(result["status"], "already_present")
        self.assertEqual(result["text"], FIXTURE)

    def test_conflict_when_handle_differs(self):
        with self.assertRaises(ValueError) as ctx:
            upsert.upsert_component_contact(
                FIXTURE, "odh-dashboard", "ai-core-platform"
            )
        self.assertIn("already exists", str(ctx.exception))


class TestUpsertNewGroup(unittest.TestCase):
    def test_inserts_new_group_before_catchall(self):
        result = upsert.upsert_component_contact(
            FIXTURE, "odh-ogx-core", "ogx-core-team"
        )
        text = result["text"]
        self.assertIn("# ogx-core-team  (1 component)", text)
        dashboard = text.index("# openshift-ai-dashboard")
        ogx = text.index("# ogx-core-team")
        catchall = text.index("# openshift-ai-devtestops-ic")
        self.assertLess(ogx, dashboard)
        self.assertLess(dashboard, catchall)
        self.assertIn("odh-ogx-core:\n    slack_team_handle: ogx-core-team\n", text)

    def test_inserts_into_catchall_alphabetically(self):
        result = upsert.upsert_component_contact(
            FIXTURE, "odh-mmm", "openshift-ai-devtestops-ic"
        )
        text = result["text"]
        self.assertIn("# openshift-ai-devtestops-ic  (3 components)", text)
        aaa = text.index("odh-aaa-ci:")
        mmm = text.index("odh-mmm:")
        zzz = text.index("odh-zzz:")
        self.assertLess(aaa, mmm)
        self.assertLess(mmm, zzz)


class TestUpsertValidation(unittest.TestCase):
    def test_rejects_missing_components_key(self):
        with self.assertRaises(ValueError):
            upsert.upsert_component_contact("foo: bar\n", "odh-x", "ai-core-platform")

    def test_rejects_invalid_handle(self):
        with self.assertRaises(ValueError):
            upsert.upsert_component_contact(FIXTURE, "odh-x", "Not A Handle")

    def test_strips_at_and_hash(self):
        result = upsert.upsert_component_contact(
            FIXTURE, "odh-lighthouse", "@ai-core-platform", "#forum-openshift-ai-operator"
        )
        self.assertIn("slack_team_handle: ai-core-platform\n", result["text"])
        self.assertIn("slack_team_channel: forum-openshift-ai-operator\n", result["text"])


if __name__ == "__main__":
    unittest.main()
