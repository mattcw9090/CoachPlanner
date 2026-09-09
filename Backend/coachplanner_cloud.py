#!/usr/bin/env python3
"""Read-only CoachPlanner access for local automation.

Database requests in this module are deliberately limited to HTTP GET. The only
POST requests are Supabase Auth login and token-refresh calls.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import fcntl
import getpass
import json
import os
import pty
import select
import subprocess
import sys
import termios
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Iterable, Mapping, Sequence
from zoneinfo import ZoneInfo


CLI_VERSION = "1.0.0"
PERTH = ZoneInfo("Australia/Perth")
KEYCHAIN_SERVICE = "com.matthewchew.CoachPlanner.automation"
DEFAULT_CONFIG_PATH = Path(__file__).with_name("coachplanner_cloud_config.json")
PAGE_SIZE = 1_000


class CoachPlannerCLIError(RuntimeError):
    """An expected, safely reportable command failure."""


@dataclass(frozen=True)
class CloudConfig:
    project_url: str
    publishable_key: str
    workspace_id: str

    @classmethod
    def load(cls, path: Path | None = None) -> "CloudConfig":
        configured_path = os.environ.get("COACHPLANNER_CLOUD_CONFIG")
        source = path or (
            Path(configured_path).expanduser()
            if configured_path
            else DEFAULT_CONFIG_PATH
        )
        try:
            payload = json.loads(source.read_text(encoding="utf-8"))
            config = cls(
                project_url=str(payload["project_url"]).rstrip("/"),
                publishable_key=str(payload["publishable_key"]),
                workspace_id=str(payload["workspace_id"]),
            )
        except (
            OSError,
            KeyError,
            TypeError,
            ValueError,
            json.JSONDecodeError,
        ) as error:
            raise CoachPlannerCLIError(
                f"Could not load cloud configuration from {source}: {error}"
            ) from error

        parsed_url = urllib.parse.urlparse(config.project_url)
        if parsed_url.scheme != "https" or not parsed_url.netloc:
            raise CoachPlannerCLIError("Cloud project URL must be a valid HTTPS URL.")
        try:
            uuid.UUID(config.workspace_id)
        except ValueError as error:
            raise CoachPlannerCLIError(
                "Cloud workspace ID is not a valid UUID."
            ) from error
        if not config.publishable_key:
            raise CoachPlannerCLIError("Cloud publishable key is missing.")
        return config


class MacOSKeychain:
    """Minimal wrapper around the macOS login Keychain."""

    def __init__(self, service: str = KEYCHAIN_SERVICE) -> None:
        self.service = service

    def read(self, account: str) -> str | None:
        result = subprocess.run(
            [
                "/usr/bin/security",
                "find-generic-password",
                "-s",
                self.service,
                "-a",
                account,
                "-w",
            ],
            text=True,
            capture_output=True,
            check=False,
        )
        if result.returncode == 0:
            return result.stdout.rstrip("\n")
        if "could not be found" in result.stderr.lower():
            return None
        raise CoachPlannerCLIError(
            f"Could not read the macOS Keychain item for {account}."
        )

    def write(self, account: str, value: str) -> None:
        if "\n" in value or "\r" in value:
            raise CoachPlannerCLIError("A Keychain value contained an invalid newline.")

        # Supplying -w without a value makes `security` prompt on a terminal,
        # so the token never appears in a process argument or shell history.
        master, slave = pty.openpty()
        attributes = termios.tcgetattr(slave)
        attributes[3] &= ~(termios.ECHO | termios.ECHONL)
        termios.tcsetattr(slave, termios.TCSANOW, attributes)

        def attach_private_terminal() -> None:
            # Detach `security` from the user's Terminal before making the
            # private pseudo-terminal its controlling terminal. Otherwise the
            # Keychain prompt can escape into the visible shell.
            os.setsid()
            fcntl.ioctl(slave, termios.TIOCSCTTY, 0)

        process = subprocess.Popen(
            [
                "/usr/bin/security",
                "add-generic-password",
                "-U",
                "-a",
                account,
                "-s",
                self.service,
                "-l",
                "CoachPlanner automation",
                "-w",
            ],
            stdin=slave,
            stdout=slave,
            stderr=slave,
            close_fds=True,
            preexec_fn=attach_private_terminal,
        )
        os.close(slave)
        output = bytearray()
        prompts_answered = 0
        deadline = time.monotonic() + 10
        try:
            while process.poll() is None and time.monotonic() < deadline:
                ready, _, _ = select.select([master], [], [], 0.1)
                if not ready:
                    continue
                try:
                    output.extend(os.read(master, 4_096))
                except OSError:
                    break
                password_prompts = output.lower().count(b"password")
                while prompts_answered < password_prompts:
                    os.write(master, value.encode("utf-8") + b"\r")
                    prompts_answered += 1
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=2)
        finally:
            os.close(master)

        if process.returncode != 0:
            raise CoachPlannerCLIError(
                f"Could not save the macOS Keychain item for {account}."
            )

    def delete(self, account: str) -> None:
        result = subprocess.run(
            [
                "/usr/bin/security",
                "delete-generic-password",
                "-s",
                self.service,
                "-a",
                account,
            ],
            text=True,
            capture_output=True,
            check=False,
        )
        if result.returncode != 0 and "could not be found" not in result.stderr.lower():
            raise CoachPlannerCLIError(
                f"Could not remove the macOS Keychain item for {account}."
            )


def _safe_api_message(raw: bytes, status: int) -> str:
    try:
        payload = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return f"HTTP {status}"
    if isinstance(payload, dict):
        for key in ("message", "error_description", "msg", "error"):
            value = payload.get(key)
            if isinstance(value, str) and value:
                return value
    return f"HTTP {status}"


def _request_json(
    url: str,
    *,
    headers: Mapping[str, str],
    method: str = "GET",
    payload: Mapping[str, Any] | None = None,
) -> Any:
    body = None if payload is None else json.dumps(payload).encode("utf-8")
    request_headers = {
        "Accept": "application/json",
        "User-Agent": f"CoachPlannerCloudCLI/{CLI_VERSION}",
    }
    request_headers.update(headers)
    if body is not None:
        request_headers["Content-Type"] = "application/json"
    request = urllib.request.Request(
        url, data=body, headers=request_headers, method=method
    )
    try:
        with urllib.request.urlopen(request, timeout=25) as response:
            raw = response.read()
    except urllib.error.HTTPError as error:
        raw = error.read()
        message = _safe_api_message(raw, error.code)
        if error.code in (401, 403):
            raise CoachPlannerCLIError(
                f"Cloud authentication failed: {message}"
            ) from error
        raise CoachPlannerCLIError(f"Supabase request failed: {message}") from error
    except urllib.error.URLError as error:
        raise CoachPlannerCLIError(
            f"Could not reach Supabase: {error.reason}"
        ) from error

    if not raw:
        return None
    try:
        return json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise CoachPlannerCLIError(
            "Supabase returned data in an unexpected format."
        ) from error


class SupabaseAuth:
    """Owns a separate CLI login session; it never alters the app's Keychain items."""

    REFRESH_TOKEN = "refresh_token"
    LEGACY_ACCOUNTS = ("access_token", "expires_at")

    def __init__(
        self, config: CloudConfig, keychain: MacOSKeychain | None = None
    ) -> None:
        self.config = config
        self.keychain = keychain or MacOSKeychain()

    @property
    def auth_headers(self) -> dict[str, str]:
        return {"apikey": self.config.publishable_key}

    def login(self, email: str, password: str) -> str:
        url = f"{self.config.project_url}/auth/v1/token?grant_type=password"
        session = _request_json(
            url,
            headers=self.auth_headers,
            method="POST",
            payload={"email": email, "password": password},
        )
        token = self._validate_and_save_session(session)
        try:
            SupabaseReadClient(self.config, token).verify_workspace()
        except Exception:
            self.logout()
            raise
        return token

    def access_token(self) -> str:
        refresh_token = self.keychain.read(self.REFRESH_TOKEN)
        if not refresh_token:
            raise CoachPlannerCLIError(
                "The cloud command is not signed in. Run `coachplanner-cloud auth login --email YOUR_EMAIL` first."
            )
        # Access tokens are long-lived enough for one command but can exceed
        # the interactive `security` tool's password limit. Keep them only in
        # process memory and exchange the short refresh token on every run.
        self._delete_legacy_access_items()
        url = f"{self.config.project_url}/auth/v1/token?grant_type=refresh_token"
        session = _request_json(
            url,
            headers=self.auth_headers,
            method="POST",
            payload={"refresh_token": refresh_token},
        )
        return self._validate_and_save_session(session)

    def has_session(self) -> bool:
        return bool(self.keychain.read(self.REFRESH_TOKEN))

    def logout(self) -> None:
        for account in (self.REFRESH_TOKEN, *self.LEGACY_ACCOUNTS):
            self.keychain.delete(account)

    def _delete_legacy_access_items(self) -> None:
        for account in self.LEGACY_ACCOUNTS:
            self.keychain.delete(account)

    def _validate_and_save_session(self, session: Any) -> str:
        if not isinstance(session, dict):
            raise CoachPlannerCLIError(
                "Supabase returned an invalid authentication session."
            )
        access_token = session.get("access_token")
        refresh_token = session.get("refresh_token")
        if not isinstance(access_token, str) or not access_token:
            raise CoachPlannerCLIError("Supabase did not return an access token.")
        if not isinstance(refresh_token, str) or not refresh_token:
            raise CoachPlannerCLIError("Supabase did not return a refresh token.")

        self.keychain.write(self.REFRESH_TOKEN, refresh_token)
        self._delete_legacy_access_items()
        return access_token


class SupabaseReadClient:
    """GET-only PostgREST client for the authenticated CoachPlanner workspace."""

    def __init__(self, config: CloudConfig, access_token: str) -> None:
        self.config = config
        self.headers = {
            "apikey": config.publishable_key,
            "Authorization": f"Bearer {access_token}",
        }

    def verify_workspace(self) -> None:
        rows = self.get_all(
            "workspaces",
            select="id",
            filters={"id": f"eq.{self.config.workspace_id}"},
            order="id.asc",
        )
        if not any(row.get("id") == self.config.workspace_id for row in rows):
            raise CoachPlannerCLIError(
                "This account cannot access the configured CoachPlanner workspace."
            )

    def get_all(
        self,
        table: str,
        *,
        select: str,
        filters: Mapping[str, str] | None = None,
        order: str | None = None,
    ) -> list[dict[str, Any]]:
        rows: list[dict[str, Any]] = []
        offset = 0
        while True:
            query: list[tuple[str, str]] = [
                ("select", select),
                ("limit", str(PAGE_SIZE)),
                ("offset", str(offset)),
            ]
            if order:
                query.append(("order", order))
            if filters:
                query.extend(filters.items())
            encoded = urllib.parse.urlencode(query)
            url = f"{self.config.project_url}/rest/v1/{table}?{encoded}"
            page = _request_json(url, headers=self.headers, method="GET")
            if not isinstance(page, list) or any(
                not isinstance(item, dict) for item in page
            ):
                raise CoachPlannerCLIError(
                    f"Supabase returned an invalid {table} response."
                )
            rows.extend(page)
            if len(page) < PAGE_SIZE:
                return rows
            offset += PAGE_SIZE

    def planning_records(self) -> dict[str, list[dict[str, Any]]]:
        workspace_filter = {"workspace_id": f"eq.{self.config.workspace_id}"}
        requests = {
            "students": (
                "students",
                "id,name,gender,sessions_demand,is_hidden,updated_at,deleted_at",
                workspace_filter,
                "name.asc,id.asc",
            ),
            "sessions": (
                "coaching_sessions",
                "id,week_start,day_of_week,start_time,end_time,venue,status,court_number,updated_at,deleted_at",
                workspace_filter,
                "start_time.asc,id.asc",
            ),
            "session_students": (
                "coaching_session_students",
                "session_id,student_id,created_at",
                None,
                "session_id.asc,student_id.asc",
            ),
            "court_bookings": (
                "court_bookings",
                "id,week_start,day_of_week,start_time,end_time,venue,court_number,updated_at,deleted_at",
                workspace_filter,
                "start_time.asc,id.asc",
            ),
            "hidden_weeks": (
                "student_hidden_weeks",
                "student_id,week_start,created_at",
                None,
                "week_start.asc,student_id.asc",
            ),
        }

        def fetch(
            spec: tuple[str, str, Mapping[str, str] | None, str]
        ) -> list[dict[str, Any]]:
            table, select, filters, order = spec
            return self.get_all(table, select=select, filters=filters, order=order)

        with concurrent.futures.ThreadPoolExecutor(
            max_workers=len(requests)
        ) as executor:
            futures = {
                name: executor.submit(fetch, spec) for name, spec in requests.items()
            }
            return {name: future.result() for name, future in futures.items()}


def _utc_now_string() -> str:
    return (
        datetime.now(tz=timezone.utc)
        .isoformat(timespec="seconds")
        .replace("+00:00", "Z")
    )


def _parse_timestamp(value: Any) -> datetime | None:
    if not isinstance(value, str) or not value:
        return None
    normalized = value[:-1] + "+00:00" if value.endswith("Z") else value
    try:
        parsed = datetime.fromisoformat(normalized)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed


def _parse_date(value: Any) -> date | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        return date.fromisoformat(value[:10])
    except ValueError:
        return None


def _week_start_for_record(record: Mapping[str, Any]) -> date | None:
    explicit = _parse_date(record.get("week_start"))
    if explicit:
        return explicit - timedelta(days=explicit.weekday())
    start = _parse_timestamp(record.get("start_time"))
    if not start:
        return None
    local_day = start.astimezone(PERTH).date()
    return local_day - timedelta(days=local_day.weekday())


def resolve_target_week(value: str, *, today: date | None = None) -> date:
    local_today = today or datetime.now(tz=PERTH).date()
    current_monday = local_today - timedelta(days=local_today.weekday())
    if value == "current":
        return current_monday
    if value == "next":
        return current_monday + timedelta(days=7)
    try:
        requested = date.fromisoformat(value)
    except ValueError as error:
        raise CoachPlannerCLIError(
            "Week must be `current`, `next`, or a Monday in YYYY-MM-DD format."
        ) from error
    if requested.weekday() != 0:
        raise CoachPlannerCLIError(
            f"{value} is not a Monday. Supply the Monday that starts the planning week."
        )
    return requested


def _latest_timestamp(records: Iterable[Mapping[str, Any]]) -> str | None:
    timestamps: list[datetime] = []
    for record in records:
        for field in ("updated_at", "created_at", "deleted_at"):
            parsed = _parse_timestamp(record.get(field))
            if parsed:
                timestamps.append(parsed)
    if not timestamps:
        return None
    return (
        max(timestamps)
        .astimezone(timezone.utc)
        .isoformat(timespec="seconds")
        .replace("+00:00", "Z")
    )


def _active(record: Mapping[str, Any]) -> bool:
    return record.get("deleted_at") is None


def _day_name(day_of_week: Any) -> str:
    names = {
        1: "Monday",
        2: "Tuesday",
        3: "Wednesday",
        4: "Thursday",
        5: "Friday",
        6: "Saturday",
        7: "Sunday",
    }
    return names.get(day_of_week, "Unknown")


def _local_time_fields(value: Any) -> tuple[str | None, str | None]:
    parsed = _parse_timestamp(value)
    if not parsed:
        return None, None
    local = parsed.astimezone(PERTH)
    return local.isoformat(timespec="minutes"), local.strftime("%H:%M")


def build_planning_snapshot(
    *,
    config: CloudConfig,
    target_week: date,
    records: Mapping[str, Sequence[Mapping[str, Any]]],
    generated_at: str | None = None,
) -> dict[str, Any]:
    baseline_week = target_week - timedelta(days=7)
    target_end = target_week + timedelta(days=6)
    baseline_end = baseline_week + timedelta(days=6)
    warnings: list[str] = []

    student_rows = list(records.get("students", []))
    session_rows = list(records.get("sessions", []))
    link_rows = list(records.get("session_students", []))
    booking_rows = list(records.get("court_bookings", []))
    hidden_rows = list(records.get("hidden_weeks", []))

    active_students = [row for row in student_rows if _active(row)]
    students_by_id = {
        str(row.get("id")): row for row in active_students if row.get("id")
    }
    target_hidden_ids = {
        str(row.get("student_id"))
        for row in hidden_rows
        if _parse_date(row.get("week_start")) == target_week
    }

    links_by_session: dict[str, set[str]] = {}
    for row in link_rows:
        session_id = str(row.get("session_id", ""))
        student_id = str(row.get("student_id", ""))
        if session_id and student_id:
            links_by_session.setdefault(session_id, set()).add(student_id)

    active_sessions = [row for row in session_rows if _active(row)]
    sessions_by_week: dict[date, list[Mapping[str, Any]]] = {
        baseline_week: [],
        target_week: [],
    }
    for row in active_sessions:
        record_week = _week_start_for_record(row)
        if record_week in sessions_by_week:
            sessions_by_week[record_week].append(row)

    active_bookings = [row for row in booking_rows if _active(row)]
    bookings_by_week: dict[date, list[Mapping[str, Any]]] = {
        baseline_week: [],
        target_week: [],
    }
    for row in active_bookings:
        record_week = _week_start_for_record(row)
        if record_week in bookings_by_week:
            bookings_by_week[record_week].append(row)

    def session_payload(row: Mapping[str, Any]) -> dict[str, Any]:
        session_id = str(row.get("id"))
        student_ids = sorted(
            links_by_session.get(session_id, set()),
            key=lambda value: str(
                students_by_id.get(value, {}).get("name", value)
            ).casefold(),
        )
        missing_ids = [
            student_id for student_id in student_ids if student_id not in students_by_id
        ]
        if missing_ids:
            warnings.append(
                f"Session {session_id} references {len(missing_ids)} unavailable student record(s)."
            )
        start_at, start_time = _local_time_fields(row.get("start_time"))
        end_at, end_time = _local_time_fields(row.get("end_time"))
        return {
            "id": session_id,
            "day_of_week": row.get("day_of_week"),
            "day": _day_name(row.get("day_of_week")),
            "start_at": start_at,
            "end_at": end_at,
            "start_time": start_time,
            "end_time": end_time,
            "venue": row.get("venue"),
            "status": row.get("status"),
            "court_number": row.get("court_number") or "",
            "student_ids": student_ids,
            "student_names": [
                str(students_by_id[student_id].get("name"))
                for student_id in student_ids
                if student_id in students_by_id
            ],
        }

    def booking_payload(row: Mapping[str, Any]) -> dict[str, Any]:
        start_at, start_time = _local_time_fields(row.get("start_time"))
        end_at, end_time = _local_time_fields(row.get("end_time"))
        return {
            "id": str(row.get("id")),
            "day_of_week": row.get("day_of_week"),
            "day": _day_name(row.get("day_of_week")),
            "start_at": start_at,
            "end_at": end_at,
            "start_time": start_time,
            "end_time": end_time,
            "venue": row.get("venue"),
            "court_number": row.get("court_number") or "",
        }

    target_session_ids = {str(row.get("id")) for row in sessions_by_week[target_week]}
    target_allocations: dict[str, int] = {
        student_id: 0 for student_id in students_by_id
    }
    for session_id in target_session_ids:
        for student_id in links_by_session.get(session_id, set()):
            if student_id in target_allocations:
                target_allocations[student_id] += 1

    students: list[dict[str, Any]] = []
    underallocated: list[dict[str, Any]] = []
    for student_id, row in students_by_id.items():
        demand = int(row.get("sessions_demand") or 0)
        allocated = target_allocations.get(student_id, 0)
        globally_hidden = bool(row.get("is_hidden"))
        hidden_for_week = globally_hidden or student_id in target_hidden_ids
        deficit = max(demand - allocated, 0)
        student = {
            "id": student_id,
            "name": row.get("name"),
            "gender": row.get("gender") or "",
            "sessions_demand": demand,
            "is_hidden_globally": globally_hidden,
            "is_hidden_for_target_week": hidden_for_week,
            "target_allocated_sessions": allocated,
            "target_allocation_deficit": deficit,
        }
        students.append(student)
        if not hidden_for_week and deficit > 0:
            underallocated.append(
                {
                    "id": student_id,
                    "name": row.get("name"),
                    "requested": demand,
                    "allocated": allocated,
                    "deficit": deficit,
                }
            )

    students.sort(key=lambda row: str(row.get("name", "")).casefold())
    underallocated.sort(
        key=lambda row: (-int(row["deficit"]), str(row.get("name", "")).casefold())
    )

    all_relevant_records: list[Mapping[str, Any]] = []
    for collection in (
        student_rows,
        session_rows,
        link_rows,
        booking_rows,
        hidden_rows,
    ):
        all_relevant_records.extend(collection)

    def week_payload(week_start: date, week_end: date) -> dict[str, Any]:
        sessions = sorted(
            (session_payload(row) for row in sessions_by_week[week_start]),
            key=lambda row: (str(row.get("start_at") or ""), str(row.get("id") or "")),
        )
        bookings = sorted(
            (booking_payload(row) for row in bookings_by_week[week_start]),
            key=lambda row: (str(row.get("start_at") or ""), str(row.get("id") or "")),
        )
        return {
            "start": week_start.isoformat(),
            "end": week_end.isoformat(),
            "sessions": sessions,
            "court_bookings": bookings,
        }

    return {
        "schema_version": 1,
        "read_only": True,
        "generated_at": generated_at or _utc_now_string(),
        "timezone": "Australia/Perth",
        "workspace_id": config.workspace_id,
        "cloud_freshness": {
            "latest_relevant_change_at": _latest_timestamp(all_relevant_records),
            "manual_device_sync_required": True,
            "note": "Changes made in the iPhone or Mac app appear here only after Sync cloud data is tapped on that device.",
        },
        "target_week": week_payload(target_week, target_end),
        "baseline_week": week_payload(baseline_week, baseline_end),
        "students": students,
        "underallocated": underallocated,
        "counts": {
            "active_students": len(active_students),
            "target_sessions": len(sessions_by_week[target_week]),
            "baseline_sessions": len(sessions_by_week[baseline_week]),
            "target_court_bookings": len(bookings_by_week[target_week]),
            "baseline_court_bookings": len(bookings_by_week[baseline_week]),
            "underallocated_students": len(underallocated),
        },
        "excluded_private_fields": [
            "student contact preference",
            "student contact detail",
            "session fees",
            "session descriptions",
        ],
        "warnings": sorted(set(warnings)),
    }


def _write_json(payload: Any, *, output: str | None, compact: bool) -> None:
    text = (
        json.dumps(
            payload,
            ensure_ascii=False,
            indent=None if compact else 2,
            separators=(",", ":") if compact else None,
            sort_keys=True,
        )
        + "\n"
    )
    if not output or output == "-":
        sys.stdout.write(text)
        return
    destination = Path(output).expanduser().resolve()
    destination.parent.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
        stream.write(text)
    os.chmod(destination, 0o600)
    sys.stdout.write(json.dumps({"output": str(destination)}) + "\n")


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="coachplanner-cloud",
        description="Read CoachPlanner planning data directly from Supabase without opening the app.",
    )
    parser.add_argument(
        "--version", action="version", version=f"%(prog)s {CLI_VERSION}"
    )
    parser.add_argument(
        "--config",
        type=Path,
        help="Override the tracked non-secret cloud configuration file.",
    )
    commands = parser.add_subparsers(dest="command", required=True)

    auth = commands.add_parser(
        "auth", help="Manage the CLI's separate Supabase session in macOS Keychain."
    )
    auth_commands = auth.add_subparsers(dest="auth_command", required=True)
    login = auth_commands.add_parser(
        "login", help="Sign in once and save only session tokens in macOS Keychain."
    )
    login.add_argument(
        "--email",
        help="Supabase Auth email. The password is always prompted for invisibly.",
    )
    auth_commands.add_parser("status", help="Check credentials and workspace access.")
    auth_commands.add_parser(
        "logout", help="Remove only the CLI's Supabase session from macOS Keychain."
    )

    snapshot = commands.add_parser(
        "snapshot", help="Print a read-only planning snapshot as JSON."
    )
    snapshot.add_argument(
        "--week",
        default="next",
        help="Target week: next (default), current, or a Monday in YYYY-MM-DD format.",
    )
    snapshot.add_argument(
        "--output",
        help="Write full JSON to this file with owner-only permissions; use - for stdout.",
    )
    snapshot.add_argument("--compact", action="store_true", help="Emit compact JSON.")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    parser = _build_parser()
    args = parser.parse_args(argv)
    try:
        config = CloudConfig.load(args.config)
        auth = SupabaseAuth(config)

        if args.command == "auth":
            if args.auth_command == "login":
                email = (args.email or input("Supabase email: ")).strip()
                if not email:
                    raise CoachPlannerCLIError("Email is required.")
                password = getpass.getpass("Supabase password: ")
                if not password:
                    raise CoachPlannerCLIError("Password is required.")
                auth.login(email, password)
                _write_json(
                    {"signed_in": True, "workspace_access": True},
                    output=None,
                    compact=False,
                )
                return 0
            if args.auth_command == "logout":
                auth.logout()
                _write_json({"signed_in": False}, output=None, compact=False)
                return 0
            if not auth.has_session():
                _write_json(
                    {"signed_in": False, "workspace_access": False},
                    output=None,
                    compact=False,
                )
                return 0
            token = auth.access_token()
            SupabaseReadClient(config, token).verify_workspace()
            _write_json(
                {"signed_in": True, "workspace_access": True},
                output=None,
                compact=False,
            )
            return 0

        if args.command == "snapshot":
            target_week = resolve_target_week(args.week)
            token = auth.access_token()
            client = SupabaseReadClient(config, token)
            client.verify_workspace()
            records = client.planning_records()
            payload = build_planning_snapshot(
                config=config, target_week=target_week, records=records
            )
            _write_json(payload, output=args.output, compact=args.compact)
            return 0
    except (CoachPlannerCLIError, KeyboardInterrupt) as error:
        message = "Cancelled." if isinstance(error, KeyboardInterrupt) else str(error)
        print(f"coachplanner-cloud: {message}", file=sys.stderr)
        return 2
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
