from __future__ import annotations

import importlib.util
import json
import sys
import unittest
from datetime import date
from pathlib import Path


MODULE_PATH = Path(__file__).parents[1] / "coachplanner_cloud.py"
SPEC = importlib.util.spec_from_file_location("coachplanner_cloud", MODULE_PATH)
assert SPEC and SPEC.loader
cloud = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = cloud
SPEC.loader.exec_module(cloud)


class TargetWeekTests(unittest.TestCase):
    def test_next_week_is_the_following_monday(self) -> None:
        self.assertEqual(
            cloud.resolve_target_week("next", today=date(2026, 9, 9)),
            date(2026, 9, 14),
        )

    def test_explicit_week_must_be_a_monday(self) -> None:
        with self.assertRaises(cloud.CoachPlannerCLIError):
            cloud.resolve_target_week("2026-09-15")


class ConfigurationTests(unittest.TestCase):
    def test_cli_configuration_matches_the_app(self) -> None:
        config = cloud.CloudConfig.load()
        swift_source = (
            MODULE_PATH.parents[1] / "CoachPlanner" / "Services" / "SupabaseCloud.swift"
        ).read_text(encoding="utf-8")
        self.assertIn(config.project_url, swift_source)
        self.assertIn(config.publishable_key, swift_source)
        self.assertIn(config.workspace_id, swift_source)


class SnapshotTests(unittest.TestCase):
    def setUp(self) -> None:
        self.config = cloud.CloudConfig(
            project_url="https://example.supabase.co",
            publishable_key="public-test-key",
            workspace_id="0db2b4f5-ff7c-4fbd-b71b-e2ddf9d5def6",
        )
        self.records = {
            "students": [
                {
                    "id": "student-a",
                    "name": "Alice",
                    "gender": "Female",
                    "sessions_demand": 2,
                    "is_hidden": False,
                    "updated_at": "2026-09-08T10:00:00Z",
                    "deleted_at": None,
                    "contact_detail": "must never be copied",
                },
                {
                    "id": "student-b",
                    "name": "Bob",
                    "gender": "Male",
                    "sessions_demand": 1,
                    "is_hidden": True,
                    "updated_at": "2026-09-08T11:00:00Z",
                    "deleted_at": None,
                },
                {
                    "id": "student-c",
                    "name": "Carol",
                    "gender": "Female",
                    "sessions_demand": 1,
                    "is_hidden": False,
                    "updated_at": "2026-09-08T12:00:00Z",
                    "deleted_at": None,
                },
            ],
            "sessions": [
                {
                    "id": "session-target",
                    "week_start": "2026-09-14",
                    "day_of_week": 1,
                    "start_time": "2026-09-14T09:00:00Z",
                    "end_time": "2026-09-14T10:00:00Z",
                    "venue": "Apex",
                    "status": "Pending",
                    "court_number": "",
                    "updated_at": "2026-09-08T13:00:00Z",
                    "deleted_at": None,
                    "session_fee": 999,
                },
                {
                    "id": "session-baseline",
                    "week_start": "2026-09-07",
                    "day_of_week": 1,
                    "start_time": "2026-09-07T09:00:00Z",
                    "end_time": "2026-09-07T10:00:00Z",
                    "venue": "Apex",
                    "status": "Confirmed",
                    "court_number": "1",
                    "updated_at": "2026-09-07T13:00:00Z",
                    "deleted_at": None,
                },
            ],
            "session_students": [
                {
                    "session_id": "session-target",
                    "student_id": "student-a",
                    "created_at": "2026-09-08T13:00:00Z",
                },
                {
                    "session_id": "session-baseline",
                    "student_id": "student-a",
                    "created_at": "2026-09-07T13:00:00Z",
                },
            ],
            "court_bookings": [],
            "hidden_weeks": [
                {
                    "student_id": "student-c",
                    "week_start": "2026-09-14",
                    "created_at": "2026-09-08T12:00:00Z",
                }
            ],
        }

    def test_snapshot_computes_allocation_and_hiding(self) -> None:
        snapshot = cloud.build_planning_snapshot(
            config=self.config,
            target_week=date(2026, 9, 14),
            records=self.records,
            generated_at="2026-09-09T00:00:00Z",
        )

        self.assertTrue(snapshot["read_only"])
        self.assertEqual(snapshot["counts"]["target_sessions"], 1)
        self.assertEqual(snapshot["counts"]["baseline_sessions"], 1)
        self.assertEqual(
            snapshot["underallocated"],
            [
                {
                    "id": "student-a",
                    "name": "Alice",
                    "requested": 2,
                    "allocated": 1,
                    "deficit": 1,
                }
            ],
        )
        students = {student["name"]: student for student in snapshot["students"]}
        self.assertTrue(students["Bob"]["is_hidden_for_target_week"])
        self.assertTrue(students["Carol"]["is_hidden_for_target_week"])
        self.assertEqual(
            snapshot["target_week"]["sessions"][0]["student_names"],
            ["Alice"],
        )

    def test_snapshot_does_not_emit_contacts_or_financial_fields(self) -> None:
        snapshot = cloud.build_planning_snapshot(
            config=self.config,
            target_week=date(2026, 9, 14),
            records=self.records,
        )
        encoded = json.dumps(snapshot)
        self.assertNotIn("must never be copied", encoded)
        self.assertNotIn("contact_detail", encoded)
        self.assertNotIn("session_fee", encoded)
        self.assertNotIn("999", encoded)

    def test_cloud_queries_do_not_request_private_planning_fields(self) -> None:
        source = MODULE_PATH.read_text(encoding="utf-8")
        planning_query_section = source.split("def planning_records", 1)[1].split(
            "def _utc_now_string", 1
        )[0]
        self.assertNotIn("contact_detail", planning_query_section)
        self.assertNotIn("contact_preference", planning_query_section)
        self.assertNotIn("session_fee", planning_query_section)
        self.assertNotIn("session_description", planning_query_section)


if __name__ == "__main__":
    unittest.main()
