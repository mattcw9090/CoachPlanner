#!/usr/bin/env python3
"""Upload a CoachPlanner export bundle to an authenticated backend.

The server must expose POST /v1/import and handle the request transactionally.
The request's idempotency key is derived from the bundle, so retrying a timed
out request cannot duplicate records.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", required=True, type=Path)
    parser.add_argument("--base-url", required=True, help="Backend base URL, for example https://api.example.com/v1")
    parser.add_argument("--token-env", default="COACHPLANNER_API_TOKEN")
    parser.add_argument("--dry-run", action="store_true", help="Validate request construction without sending it")
    args = parser.parse_args()

    try:
        payload = args.bundle.read_bytes()
        bundle = json.loads(payload)
    except (OSError, json.JSONDecodeError) as error:
        print(f"Could not read bundle: {error}", file=sys.stderr)
        return 1

    if bundle.get("format") != "coachplanner-import" or bundle.get("formatVersion") != 1:
        print("Unsupported import bundle format", file=sys.stderr)
        return 1

    idempotency_key = hashlib.sha256(payload).hexdigest()
    endpoint = args.base_url.rstrip("/") + "/import"
    request = urllib.request.Request(
        endpoint,
        data=payload,
        method="POST",
        headers={
            "Accept": "application/json",
            "Content-Type": "application/json",
            "Idempotency-Key": idempotency_key,
        },
    )

    if args.dry_run:
        print(json.dumps({"endpoint": endpoint, "idempotencyKey": idempotency_key, "sent": False}, indent=2))
        return 0

    token = os.environ.get(args.token_env)
    if not token:
        print(f"Missing bearer token in environment variable {args.token_env}", file=sys.stderr)
        return 1
    request.add_header("Authorization", f"Bearer {token}")

    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            response_body = response.read().decode("utf-8")
            print(response_body or json.dumps({"status": response.status}))
    except urllib.error.HTTPError as error:
        body = error.read().decode("utf-8", errors="replace")
        print(f"Import failed with HTTP {error.code}: {body}", file=sys.stderr)
        return 1
    except urllib.error.URLError as error:
        print(f"Import request failed: {error.reason}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
