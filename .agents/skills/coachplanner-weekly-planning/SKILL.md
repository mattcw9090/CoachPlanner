---
name: coachplanner-weekly-planning
description: Plan or review Matthew's upcoming badminton coaching week from CoachPlanner's read-only Supabase snapshot and private scheduling profile. Use for weekly timetable planning, underallocation review, or scheduled CoachPlanner planning runs. Do not use for sending messages, booking courts, changing session statuses, or writing app or cloud data.
---

# CoachPlanner Weekly Planning

Produce a fast, reviewable timetable draft from the cloud snapshot. Keep the entire workflow read-only until Matthew explicitly approves a later action.

## Read the authoritative inputs

Work from the CoachPlanner repository root.

1. Read the repository `AGENTS.md` and `README.md`.
2. Read `PrivatePlanning/SchedulingProfile.md` when it exists. It is local-only. Never quote or move its contents into tracked files. If it is missing, disclose that private scheduling rules were unavailable; do not invent or initialize them during an unattended run.
3. Check the CLI session:

   ```sh
   Tools/coachplanner-cloud auth status
   ```

   Continue only when it reports both `signed_in: true` and `workspace_access: true`. If not, stop and tell Matthew to perform the one-time interactive login himself:

   ```sh
   Tools/coachplanner-cloud auth login --email YOUR_EMAIL
   ```

   Never request, capture, or store his password during a scheduled run.
4. Fetch the requested Monday-Sunday week. Use `next` when the request says next or following week; otherwise pass the requested Monday in `YYYY-MM-DD` form:

   ```sh
   Tools/coachplanner-cloud snapshot --week next --compact
   ```

   The command is the preferred data path. Do not open or control the CoachPlanner UI to rediscover the same data when it succeeds. If it fails, report the exact blocker and do not fabricate records or silently switch to UI automation.

## Validate and interpret the snapshot

- Require `schema_version: 1` and `read_only: true`. Stop with a clear compatibility warning if either differs.
- Confirm `target_week.start` and `target_week.end` match the week being planned.
- Report `cloud_freshness.latest_relevant_change_at`. The apps sync explicitly, so disclose that device edits made after the last manual **Sync cloud data** action may be absent.
- Surface every item in `warnings` before recommending changes.
- Treat existing `target_week.sessions` as the current draft. Never copy or duplicate the baseline merely because `baseline_week.sessions` exists.
- Use `underallocated` for unmet demand. It already excludes students hidden globally or for the target week; use `students` when the hidden state or allocation count needs explanation.
- Treat an empty week or empty booking list as valid data, not as permission to invent records.

Apply permanent rules from the private profile. Apply a dated exception only when its dates overlap the target week, and ignore expired exceptions. Availability that is not in the snapshot or applicable profile remains unknown.

## Draft the plan

Preserve stable existing arrangements first. Then suggest the smallest set of additions or moves that improves demand coverage while respecting confirmed availability, required groupings, session duration, venue preferences, travel, court cost, and idle gaps.

Clearly distinguish:

- sessions already present in the cloud snapshot;
- proposed additions or changes that do not yet exist;
- students who remain underallocated;
- assumptions, conflicts, and availability Matthew still needs to decide.

If the target week is already populated, review and refine it instead of rebuilding it. If there is not enough confirmed availability to place someone, leave them unresolved rather than guessing.

Return a compact preview containing the source freshness, target dates, existing-session summary, proposed timetable changes, remaining underallocation, and the next decisions required from Matthew. End at the approval gate.

## Boundaries

This skill never writes to Supabase or SwiftData, creates or moves sessions, changes statuses, sends availability messages, books courts, makes payments, or exports finance or calendar data. Those are separate supervised stages and require Matthew's explicit approval at the time of the action.

Treat corrections as candidate hard rules, soft preferences, or dated exceptions, but do not edit the private scheduling profile unless Matthew explicitly asks to save them. Never put contact details, social handles, message contents, fees, or other sensitive data into the profile or the draft.
