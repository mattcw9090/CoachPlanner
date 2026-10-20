-- Explicit Data API grants for every public CoachPlanner table.
-- Idempotent. Does not insert, update, or delete rows.
-- Apply after schema.sql on a database whose roles include anon,
-- authenticated, and service_role. Safe to run again: grant repeats, and
-- revoke leaves anon with no table privileges.
-- The iPhone, Mac, and planning client call PostgREST with a signed-in user
-- JWT. The publishable key is only the apikey header. anon never queries
-- these tables, so it is granted nothing.

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
