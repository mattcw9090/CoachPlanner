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
  created_at timestamptz not null default now(),
  primary key (session_id, student_id)
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
