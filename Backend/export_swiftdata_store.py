#!/usr/bin/env python3
"""Read-only exporter for a CoachPlanner SwiftData SQLite store.

The output is an import bundle, not a live sync client. It deliberately uses
the Core Data integer primary keys only as temporary migration references and
emits stable UUIDs for the cloud schema.
"""

from __future__ import annotations

import argparse
import json
import sqlite3
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

APPLE_EPOCH = 978307200
EXPORT_NAMESPACE = uuid.UUID("7b7657a1-b68e-4b36-8f7e-93868b6a7e1c")


def cloud_id(entity: str, primary_key: int) -> str:
    return str(uuid.uuid5(EXPORT_NAMESPACE, f"{entity}:{primary_key}"))


def iso_date(value: float | None) -> str | None:
    if value is None:
        return None
    return datetime.fromtimestamp(float(value) + APPLE_EPOCH, tz=timezone.utc).isoformat()


def date_only(value: float | None) -> str | None:
    timestamp = iso_date(value)
    return timestamp[:10] if timestamp else None


def rows(connection: sqlite3.Connection, query: str) -> list[sqlite3.Row]:
    return connection.execute(query).fetchall()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--store", required=True, type=Path, help="Path to CoachPlanner.store")
    parser.add_argument("--output", required=True, type=Path, help="Output JSON import bundle")
    parser.add_argument("--workspace-id", required=True, help="UUID for the target cloud workspace")
    args = parser.parse_args()

    try:
        workspace_id = str(uuid.UUID(args.workspace_id))
    except ValueError as error:
        parser.error(f"--workspace-id must be a UUID: {error}")

    if not args.store.is_file():
        parser.error(f"Store does not exist: {args.store}")

    # URI mode=ro ensures this migration tool cannot write to the source store.
    connection = sqlite3.connect(f"file:{args.store.resolve()}?mode=ro", uri=True)
    connection.row_factory = sqlite3.Row

    try:
        student_rows = rows(connection, "select * from ZSTUDENT order by Z_PK")
        outsider_rows = rows(connection, "select * from ZOUTSIDER order by Z_PK")
        coaching_rows = rows(connection, "select * from ZCOACHINGSESSION order by Z_PK")
        booking_rows = rows(connection, "select * from ZCOURTBOOKING order by Z_PK")
        social_rows = rows(connection, "select * from ZSOCIALSESSION order by Z_PK")
        hidden_week_rows = rows(connection, "select * from ZSTUDENTHIDDENWEEK order by Z_PK")
        hidden_person_rows = rows(connection, "select * from ZSOCIALHIDDENPERSON order by Z_PK")
        attendance_rows = rows(connection, "select * from ZSOCIALATTENDANCE order by Z_PK")

        student_ids = {row["Z_PK"]: cloud_id("student", row["Z_PK"]) for row in student_rows}
        outsider_ids = {row["Z_PK"]: cloud_id("outsider", row["Z_PK"]) for row in outsider_rows}
        coaching_ids = {row["Z_PK"]: cloud_id("coaching_session", row["Z_PK"]) for row in coaching_rows}
        booking_ids = {row["Z_PK"]: cloud_id("court_booking", row["Z_PK"]) for row in booking_rows}
        social_ids = {row["Z_PK"]: cloud_id("social_session", row["Z_PK"]) for row in social_rows}

        coaching_students = rows(connection, "select Z_1SESSIONS, Z_7STUDENTS from Z_1STUDENTS order by Z_1SESSIONS, Z_7STUDENTS")
        social_students = rows(connection, "select Z_6SOCIALSESSIONS, Z_7STUDENTS1 from Z_6STUDENTS order by Z_6SOCIALSESSIONS, Z_7STUDENTS1")

        def require(mapping: dict[int, str], key: int, label: str) -> str:
            if key not in mapping:
                raise ValueError(f"Orphaned {label} relationship references SQLite row {key}")
            return mapping[key]

        session_students: dict[int, list[str]] = {}
        for relation in coaching_students:
            session_students.setdefault(relation["Z_1SESSIONS"], []).append(
                require(student_ids, relation["Z_7STUDENTS"], "coaching student")
            )

        social_student_links: dict[int, list[str]] = {}
        for relation in social_students:
            social_student_links.setdefault(relation["Z_6SOCIALSESSIONS"], []).append(
                require(student_ids, relation["Z_7STUDENTS1"], "social student")
            )

        bundle: dict[str, Any] = {
            "format": "coachplanner-import",
            "formatVersion": 1,
            "workspaceId": workspace_id,
            "exportedAt": datetime.now(timezone.utc).isoformat(),
            "source": {"kind": "swiftdata-sqlite", "path": str(args.store.resolve())},
            "students": [
                {
                    "id": student_ids[row["Z_PK"]],
                    "name": row["ZNAME"],
                    "gender": row["ZGENDER"] or "",
                    "contactPreference": row["ZCONTACTPREFERENCE"] or "Instagram",
                    "contactDetail": row["ZCONTACTDETAIL"] or "",
                    "sessionsDemand": row["ZSESSIONSDEMAND"] or 0,
                    "isHidden": bool(row["ZISHIDDEN"]),
                    "createdAt": iso_date(row["ZCREATEDAT"]),
                }
                for row in student_rows
            ],
            "outsiders": [
                {
                    "id": outsider_ids[row["Z_PK"]],
                    "name": row["ZNAME"],
                    "gender": row["ZGENDER"] or "",
                    "contactPreference": row["ZCONTACTPREFERENCE"] or "Instagram",
                    "contactDetail": row["ZCONTACTDETAIL"] or "",
                    "createdAt": iso_date(row["ZCREATEDAT"]),
                }
                for row in outsider_rows
            ],
            "coachingSessions": [
                {
                    "id": coaching_ids[row["Z_PK"]],
                    "weekStart": date_only(row["ZWEEKSTART"]),
                    "dayOfWeek": row["ZDAYOFWEEK"],
                    "startTime": iso_date(row["ZSTARTTIME"]),
                    "endTime": iso_date(row["ZENDTIME"]),
                    "venue": row["ZVENUE"],
                    "status": row["ZSTATUS"],
                    "courtNumber": row["ZCOURTNUMBER"] or "",
                    "sessionFee": row["ZSESSIONFEE"] or 0,
                    "sessionDescription": row["ZSESSIONDESCRIPTION"],
                    "studentIds": session_students.get(row["Z_PK"], []),
                    "createdAt": iso_date(row["ZCREATEDAT"]),
                }
                for row in coaching_rows
            ],
            "courtBookings": [
                {
                    "id": booking_ids[row["Z_PK"]],
                    "weekStart": date_only(row["ZWEEKSTART"]),
                    "dayOfWeek": row["ZDAYOFWEEK"],
                    "startTime": iso_date(row["ZSTARTTIME"]),
                    "endTime": iso_date(row["ZENDTIME"]),
                    "venue": row["ZVENUE"],
                    "courtNumber": row["ZCOURTNUMBER"],
                    "createdAt": iso_date(row["ZCREATEDAT"]),
                }
                for row in booking_rows
            ],
            "socialSessions": [
                {
                    "id": social_ids[row["Z_PK"]],
                    "title": row["ZTITLE"],
                    "weekStart": date_only(row["ZWEEKSTART"]),
                    "dayOfWeek": row["ZDAYOFWEEK"],
                    "startTime": iso_date(row["ZSTARTTIME"]),
                    "endTime": iso_date(row["ZENDTIME"]),
                    "venue": row["ZVENUE"],
                    "status": row["ZSTATUS"],
                    "areCourtsBooked": bool(row["ZARECOURTSBOOKED"]),
                    "courtNumbers": row["ZCOURTNUMBERS"] or "",
                    "shuttlecockCost": row["ZSHUTTLECOCKCOST"] or 0,
                    "courtCost": row["ZCOURTCOST"] or 0,
                    "studentIds": social_student_links.get(row["Z_PK"], []),
                    "createdAt": iso_date(row["ZCREATEDAT"]),
                }
                for row in social_rows
            ],
            "studentHiddenWeeks": [
                {
                    "studentId": require(student_ids, row["ZSTUDENT"], "hidden-week student"),
                    "weekStart": date_only(row["ZWEEKSTART"]),
                    "createdAt": iso_date(row["ZCREATEDAT"]),
                }
                for row in hidden_week_rows
            ],
            "socialHiddenPeople": [
                {
                    "id": cloud_id("social_hidden_person", row["Z_PK"]),
                    "socialSessionId": require(social_ids, row["ZSESSION"], "hidden-person session"),
                    "studentId": student_ids.get(row["ZSTUDENT"]),
                    "outsiderId": outsider_ids.get(row["ZOUTSIDER"]),
                    "createdAt": iso_date(row["ZCREATEDAT"]),
                }
                for row in hidden_person_rows
            ],
            "socialAttendance": [
                {
                    "id": cloud_id("social_attendance", row["Z_PK"]),
                    "socialSessionId": require(social_ids, row["ZSESSION"], "attendance session"),
                    "studentId": student_ids.get(row["ZSTUDENT"]),
                    "outsiderId": outsider_ids.get(row["ZOUTSIDER"]),
                    "status": row["ZSTATUS"],
                    "paymentStatus": row["ZPAYMENTSTATUS"],
                    "createdAt": iso_date(row["ZCREATEDAT"]),
                }
                for row in attendance_rows
            ],
        }
    except (KeyError, ValueError, sqlite3.Error) as error:
        print(f"Export failed: {error}", file=sys.stderr)
        return 1
    finally:
        connection.close()

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(bundle, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    counts = {key: len(value) for key, value in bundle.items() if isinstance(value, list)}
    print(json.dumps({"output": str(args.output.resolve()), "counts": counts}, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
