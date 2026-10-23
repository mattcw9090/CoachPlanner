-- Backend/migrations/2026-10-23_add_social_session.sql
-- Adds one social (social_sessions + social_attendance + social_session_students)
-- in a single RPC call, the same rows the app's Edit Socials sheet produces.
-- No schema change: courts stay blank (are_courts_booked = false, court_numbers = '') until booked.
-- Matthew (outsider 'Matt Chew') is always a participant, always Confirmed.
-- Everyone else starts at p_attendance_status (default Unscheduled, like the app) / Unpaid.

create or replace function public.add_social_session(
  p_date date,
  p_start_local time,
  p_end_local time,
  p_venue text,
  p_include_everyone boolean default true,
  p_participant_ids uuid[] default null,
  p_title text default 'Badminton Socials',
  p_attendance_status text default 'Unscheduled'
)
returns uuid
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_workspace_id uuid;
  v_owner_outsider_id uuid;
  v_owner_matches int;
  v_start timestamptz;
  v_end timestamptz;
  v_dow smallint;
  v_week_start date;
  v_session_id uuid;
  v_unknown uuid[];
begin
  -- Owner's workspace (RLS also restricts every statement below to it).
  select w.id into v_workspace_id from workspaces w where w.owner_user_id = auth.uid();
  if v_workspace_id is null then
    raise exception using errcode = '42501', message = 'Workspace is unavailable.';
  end if;

  if p_date is null or p_start_local is null or p_end_local is null then
    raise exception using errcode = '22023', message = 'p_date, p_start_local and p_end_local are required.';
  end if;
  -- Same values as the app's Venue enum.
  if p_venue is null or p_venue not in ('PBA Malaga', 'PBA Canningvale', 'Apex', 'TRS') then
    raise exception using errcode = '22023',
      message = format('p_venue must be one of PBA Malaga, PBA Canningvale, Apex, TRS; got %L', p_venue);
  end if;
  if p_attendance_status is null or p_attendance_status not in ('Unscheduled', 'Pending', 'Confirmed') then
    raise exception using errcode = '22023', message = format('Invalid p_attendance_status %L', p_attendance_status);
  end if;
  if p_start_local = p_end_local then
    raise exception using errcode = '22023', message = 'Start and end time must differ.';
  end if;

  -- Matthew himself (outsider 'Matt Chew') joins every social. Looked up by name, never hard-coded.
  select count(*), min(o.id::text)::uuid into v_owner_matches, v_owner_outsider_id
  from outsiders o
  where o.workspace_id = v_workspace_id and o.deleted_at is null
    and lower(btrim(o.name)) = 'matt chew';
  if v_owner_matches <> 1 then
    raise exception using errcode = 'P0002',
      message = format('Expected exactly one live outsider named ''Matt Chew'' in this workspace, found %s. Add or fix that outsider first.', v_owner_matches);
  end if;

  -- Perth wall-clock -> UTC. An end before the start means it runs past midnight.
  v_start := (p_date + p_start_local) at time zone 'Australia/Perth';
  v_end := (p_date + p_end_local
            + case when p_end_local < p_start_local then interval '1 day' else interval '0' end)
           at time zone 'Australia/Perth';
  v_dow := extract(isodow from p_date)::smallint;           -- Monday = 1
  v_week_start := p_date - (v_dow - 1);                     -- Monday of that week

  -- Explicit participants must be live students or outsiders in this workspace.
  if p_participant_ids is not null then
    select array_agg(x.id) into v_unknown
    from unnest(p_participant_ids) as x(id)
    where not exists (select 1 from students s where s.id = x.id and s.workspace_id = v_workspace_id and s.deleted_at is null)
      and not exists (select 1 from outsiders o where o.id = x.id and o.workspace_id = v_workspace_id and o.deleted_at is null);
    if v_unknown is not null then
      raise exception using errcode = '23503',
        message = format('Unknown, deleted or foreign participant ids: %s', array_to_string(v_unknown, ', '));
    end if;
  end if;

  -- Idempotency: one live social per workspace + venue + start time.
  -- A retry (or double tap) returns the existing id and changes nothing.
  perform pg_advisory_xact_lock(hashtextextended(
    v_workspace_id::text || '|social|' || p_venue || '|' || extract(epoch from v_start)::bigint::text, 0));
  select ss.id into v_session_id
  from social_sessions ss
  where ss.workspace_id = v_workspace_id and ss.venue = p_venue
    and ss.start_time = v_start and ss.deleted_at is null
  limit 1;
  if v_session_id is not null then
    raise notice 'Social % already exists for % at %; returning it unchanged.', v_session_id, p_venue, v_start;
    return v_session_id;
  end if;

  insert into social_sessions (workspace_id, title, week_start, day_of_week, start_time, end_time,
                               venue, status, are_courts_booked, court_numbers)
  values (v_workspace_id, coalesce(nullif(btrim(p_title), ''), 'Badminton Socials'), v_week_start, v_dow,
          v_start, v_end, p_venue, 'Planned', false, '')
  returning id into v_session_id;

  -- Participants: everyone live (non-hidden students + outsiders), and/or the given ids, plus Matt Chew.
  -- Explicitly listed students are included even if hidden.
  -- Each person is selected once from their own table, so no duplicates are possible.
  insert into social_attendance (social_session_id, student_id, outsider_id, status, payment_status)
  select v_session_id, s.id, null, p_attendance_status, 'Unpaid'
  from students s
  where s.workspace_id = v_workspace_id and s.deleted_at is null
    and ((p_include_everyone and not s.is_hidden) or s.id = any(coalesce(p_participant_ids, '{}')))
  union all
  select v_session_id, null, o.id,
         case when o.id = v_owner_outsider_id then 'Confirmed' else p_attendance_status end, 'Unpaid'
  from outsiders o
  where o.workspace_id = v_workspace_id and o.deleted_at is null
    and (p_include_everyone or o.id = v_owner_outsider_id or o.id = any(coalesce(p_participant_ids, '{}')));

  -- The app mirrors selected students into social_session_students.
  insert into social_session_students (session_id, student_id)
  select v_session_id, a.student_id
  from social_attendance a
  where a.social_session_id = v_session_id and a.student_id is not null;

  -- social_hidden_people is left empty: "hidden" only hides a person from the add list.
  return v_session_id;
end;
$$;

comment on function public.add_social_session(date, time, time, text, boolean, uuid[], text, text) is
  'Adds a Planned social with courts unbooked: Perth date + local times -> UTC start/end, week_start (Monday), day_of_week (Monday = 1). Participants = all live non-hidden students and all live outsiders by default, or only p_participant_ids (students or outsiders). The outsider Matt Chew is always included and always Confirmed; everyone else starts at p_attendance_status (default Unscheduled) and Unpaid. Idempotent per venue + start time: an existing live social is returned unchanged.';

revoke all on function public.add_social_session(date, time, time, text, boolean, uuid[], text, text) from public, anon;
grant execute on function public.add_social_session(date, time, time, text, boolean, uuid[], text, text) to authenticated, service_role;
