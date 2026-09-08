# Weekly Planning Workflow

This guide explains the repeatable coaching-planning flow without storing student contact details or personal availability notes in version control.

## Sources of truth

| Concern | Location | Notes |
| --- | --- | --- |
| Sessions, students, venues, statuses and court bookings | SwiftData store through CoachPlanner | The app remains the operational source of truth. |
| Stable and week-specific coaching rules | `PrivatePlanning/SchedulingProfile.md` | Local-only and Git-excluded. Read it when present. |
| Automation exchange format | `Features/Automation/PlanningAutomationView.swift` | Snapshot and draft JSON contracts. |

## Safe sequence

1. Select the target week in **Automation** and refresh its snapshot.
2. Draft a JSON timetable using names and venues from that snapshot.
3. Preview the draft. Resolve every error before applying it; warnings need an explicit coaching decision.
4. Apply only after the timetable is approved.
   - `replacesWeek: false` adds new Unscheduled sessions.
   - `replacesWeek: true` replaces the week's coaching sessions after a destructive confirmation. It does not alter court bookings, but existing session status, fee and court-number data is not preserved by the present draft format.
5. Prepare availability messages only after the timetable is approved. Sending messages and changing sessions to Pending remain separate, explicit actions.

## Draft JSON contract

```json
{
  "weekStart": "2026-09-14",
  "replacesWeek": false,
  "sessions": [
    {
      "id": "monday-1700-apex",
      "dayOfWeek": 1,
      "startTime": "17:00",
      "endTime": "18:00",
      "venue": "Apex",
      "studentNames": ["Student Name"]
    }
  ]
}
```

`dayOfWeek` is 1 for Monday through 7 for Sunday. Times are local 24-hour `HH:mm` values. Valid venues come from the snapshot.

## Preview checks

The current preview catches:

- Target-week mismatch.
- Unknown or hidden students.
- Unsupported venues and invalid time ranges.
- Student overlaps within the draft, and against existing sessions for additive drafts.
- Underallocation relative to each student's session demand.

It intentionally does not infer personal availability. Add or update that information only in the local scheduling profile after a direct coaching decision.
