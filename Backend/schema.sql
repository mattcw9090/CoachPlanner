-- CoachPlanner cloud schema, PostgreSQL 15+
-- Apply inside a private database after enabling UUID generation.

create extension if not exists pgcrypto;

create or replace function set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create table if not exists workspaces (
  id uuid primary key default gen_random_uuid(),
  owner_user_id uuid not null,
  name text not null default 'CoachPlanner',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists students (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references workspaces(id) on delete cascade,
  name text not null,
  gender text not null default '',
  contact_preference text not null default 'Instagram',
  contact_detail text not null default '',
  sessions_demand integer not null default 1 check (sessions_demand >= 0),
  is_hidden boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);

create table if not exists outsiders (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references workspaces(id) on delete cascade,
  name text not null,
  gender text not null default '',
  contact_preference text not null default 'Instagram',
  contact_detail text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);

create table if not exists coaching_sessions (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references workspaces(id) on delete cascade,
  week_start date,
  day_of_week smallint not null check (day_of_week between 1 and 7),
  start_time timestamptz not null,
  end_time timestamptz not null,
  venue text not null,
  status text not null default 'Unscheduled',
  court_number text not null default '',
  session_fee numeric(10,2) not null default 0,
  session_description text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  check (end_time > start_time)
);

create table if not exists coaching_session_students (
  session_id uuid not null references coaching_sessions(id) on delete cascade,
  student_id uuid not null references students(id) on delete restrict,
  status text not null default 'Pending',
  responded_at timestamptz,
  created_at timestamptz not null default now(),
  primary key (session_id, student_id),
  constraint coaching_session_students_status_check check (status in ('Pending', 'Confirmed', 'Declined'))
);

create table if not exists court_bookings (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references workspaces(id) on delete cascade,
  week_start date,
  day_of_week smallint not null check (day_of_week between 1 and 7),
  start_time timestamptz not null,
  end_time timestamptz not null,
  venue text not null,
  court_number text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  check (end_time > start_time)
);

create table if not exists social_sessions (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references workspaces(id) on delete cascade,
  title text not null default 'Badminton Socials',
  week_start date not null,
  day_of_week smallint not null check (day_of_week between 1 and 7),
  start_time timestamptz not null,
  end_time timestamptz not null,
  venue text not null,
  status text not null default 'Planned',
  are_courts_booked boolean not null default false,
  court_numbers text not null default '',
  shuttlecock_cost numeric(10,2) not null default 0,
  court_cost numeric(10,2) not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  check (end_time > start_time)
);

create table if not exists social_session_students (
  session_id uuid not null references social_sessions(id) on delete cascade,
  student_id uuid not null references students(id) on delete restrict,
  created_at timestamptz not null default now(),
  primary key (session_id, student_id)
);

create table if not exists student_hidden_weeks (
  student_id uuid not null references students(id) on delete cascade,
  week_start date not null,
  created_at timestamptz not null default now(),
  primary key (student_id, week_start)
);

create table if not exists social_hidden_people (
  id uuid primary key default gen_random_uuid(),
  social_session_id uuid not null references social_sessions(id) on delete cascade,
  student_id uuid references students(id) on delete cascade,
  outsider_id uuid references outsiders(id) on delete cascade,
  created_at timestamptz not null default now(),
  check ((student_id is not null) <> (outsider_id is not null))
);

create table if not exists social_attendance (
  id uuid primary key default gen_random_uuid(),
  social_session_id uuid not null references social_sessions(id) on delete cascade,
  student_id uuid references students(id) on delete cascade,
  outsider_id uuid references outsiders(id) on delete cascade,
  status text not null default 'Unscheduled',
  payment_status text not null default 'Unpaid',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check ((student_id is not null) <> (outsider_id is not null))
);

create index if not exists students_workspace_updated_idx on students(workspace_id, updated_at);
create index if not exists coaching_sessions_workspace_week_idx on coaching_sessions(workspace_id, week_start, start_time);
create index if not exists court_bookings_workspace_week_idx on court_bookings(workspace_id, week_start, start_time);
create index if not exists social_sessions_workspace_week_idx on social_sessions(workspace_id, week_start, start_time);

drop trigger if exists students_set_updated_at on students;
create trigger students_set_updated_at before update on students for each row execute function set_updated_at();
drop trigger if exists outsiders_set_updated_at on outsiders;
create trigger outsiders_set_updated_at before update on outsiders for each row execute function set_updated_at();
drop trigger if exists coaching_sessions_set_updated_at on coaching_sessions;
create trigger coaching_sessions_set_updated_at before update on coaching_sessions for each row execute function set_updated_at();
drop trigger if exists court_bookings_set_updated_at on court_bookings;
create trigger court_bookings_set_updated_at before update on court_bookings for each row execute function set_updated_at();
drop trigger if exists social_sessions_set_updated_at on social_sessions;
create trigger social_sessions_set_updated_at before update on social_sessions for each row execute function set_updated_at();
drop trigger if exists social_attendance_set_updated_at on social_attendance;
create trigger social_attendance_set_updated_at before update on social_attendance for each row execute function set_updated_at();

-- Relationship edits advance the owning record's version so another device
-- can safely detect student-list, hidden-week, and attendance-only changes.
create or replace function touch_coaching_session_from_link()
returns trigger language plpgsql as $$
declare
  target_session_id uuid;
begin
  if tg_op = 'DELETE' then
    target_session_id := old.session_id;
  else
    target_session_id := new.session_id;
  end if;

  update coaching_sessions
  set updated_at = now()
  where id = target_session_id;

  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;

create or replace function touch_social_session_from_link()
returns trigger language plpgsql as $$
declare
  target_session_id uuid;
begin
  if tg_table_name = 'social_session_students' then
    if tg_op = 'DELETE' then
      target_session_id := old.session_id;
    else
      target_session_id := new.session_id;
    end if;
  else
    if tg_op = 'DELETE' then
      target_session_id := old.social_session_id;
    else
      target_session_id := new.social_session_id;
    end if;
  end if;

  update social_sessions
  set updated_at = now()
  where id = target_session_id;

  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;

create or replace function touch_student_from_hidden_week()
returns trigger language plpgsql as $$
declare
  target_student_id uuid;
begin
  if tg_op = 'DELETE' then
    target_student_id := old.student_id;
  else
    target_student_id := new.student_id;
  end if;

  update students
  set updated_at = now()
  where id = target_student_id;

  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;

drop trigger if exists coaching_session_students_touch_parent on coaching_session_students;
create trigger coaching_session_students_touch_parent after insert or update or delete on coaching_session_students
for each row execute function touch_coaching_session_from_link();

drop trigger if exists social_session_students_touch_parent on social_session_students;
create trigger social_session_students_touch_parent after insert or update or delete on social_session_students
for each row execute function touch_social_session_from_link();

drop trigger if exists social_hidden_people_touch_parent on social_hidden_people;
create trigger social_hidden_people_touch_parent after insert or update or delete on social_hidden_people
for each row execute function touch_social_session_from_link();

drop trigger if exists social_attendance_touch_parent on social_attendance;
create trigger social_attendance_touch_parent after insert or update or delete on social_attendance
for each row execute function touch_social_session_from_link();

drop trigger if exists student_hidden_weeks_touch_parent on student_hidden_weeks;
create trigger student_hidden_weeks_touch_parent after insert or update or delete on student_hidden_weeks
for each row execute function touch_student_from_hidden_week();

-- Supabase deployment hardening. The authenticated user may only access rows
-- belonging to a workspace they own. Service-role server functions bypass RLS
-- for the one-time migration import.
alter table workspaces enable row level security;
alter table students enable row level security;
alter table outsiders enable row level security;
alter table coaching_sessions enable row level security;
alter table coaching_session_students enable row level security;
alter table court_bookings enable row level security;
alter table social_sessions enable row level security;
alter table social_session_students enable row level security;
alter table student_hidden_weeks enable row level security;
alter table social_hidden_people enable row level security;
alter table social_attendance enable row level security;

-- Data API privileges. Recreating these tables does not receive automatic
-- grants. The app reads and writes only with a signed-in user JWT, so anon
-- gets none. authenticated and service_role keep select, insert, update, and
-- delete. Keep this list matched with migrations/2026-10-21_public_table_grants.sql.
revoke all on table
  public.workspaces,
  public.students,
  public.outsiders,
  public.coaching_sessions,
  public.coaching_session_students,
  public.court_bookings,
  public.social_sessions,
  public.social_session_students,
  public.student_hidden_weeks,
  public.social_hidden_people,
  public.social_attendance
from anon;

grant select, insert, update, delete on table
  public.workspaces,
  public.students,
  public.outsiders,
  public.coaching_sessions,
  public.coaching_session_students,
  public.court_bookings,
  public.social_sessions,
  public.social_session_students,
  public.student_hidden_weeks,
  public.social_hidden_people,
  public.social_attendance
to authenticated, service_role;

-- Move Sessions. Same definition, comment, and grants as
-- migrations/2026-10-21_reset_coaching_week.sql.
create or replace function public.reset_coaching_week(
  p_from_week date default (date_trunc('week', (now() at time zone 'Australia/Perth'))::date)
)
returns integer
language plpgsql
security invoker
set search_path = public
as $$
declare
  moved integer;
begin
  if extract(isodow from p_from_week) <> 1 then
    raise exception 'p_from_week must be a Monday, got %', p_from_week;
  end if;

  with targets as (
    select id from coaching_sessions
    where week_start = p_from_week and deleted_at is null
  ), reset_students as (
    update coaching_session_students s
    set status = 'Pending', responded_at = null
    from targets t
    where s.session_id = t.id
    returning s.session_id
  )
  update coaching_sessions c
  set week_start = p_from_week + 7,
      start_time = c.start_time + interval '7 days',
      end_time = c.end_time + interval '7 days',
      status = 'Unscheduled',
      court_number = ''
  from targets t
  where c.id = t.id;

  get diagnostics moved = row_count;
  return moved;
end;
$$;

comment on function public.reset_coaching_week(date) is
  'Same as the app''s Move Sessions button: moves a week''s live coaching sessions to the next week, keeps students and fees, sets them Unscheduled, clears court numbers and resets each student to Pending.';

revoke all on function public.reset_coaching_week(date) from public, anon;
grant execute on function public.reset_coaching_week(date) to authenticated, service_role;

-- Add a social. Same definition, comment, and grants as
-- migrations/2026-10-23_add_social_session.sql.
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
