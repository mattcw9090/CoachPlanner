-- Run after schema.sql and after the Auth user/workspace exist.
-- These policies are deliberately owner-scoped; the server-side service role
-- used by the migration importer bypasses them.

create policy workspace_owner on public.workspaces for all to authenticated
using (owner_user_id = auth.uid())
with check (owner_user_id = auth.uid());

create policy students_owner on public.students for all to authenticated
using (exists (select 1 from public.workspaces w where w.id = workspace_id and w.owner_user_id = auth.uid()))
with check (exists (select 1 from public.workspaces w where w.id = workspace_id and w.owner_user_id = auth.uid()));

create policy outsiders_owner on public.outsiders for all to authenticated
using (exists (select 1 from public.workspaces w where w.id = workspace_id and w.owner_user_id = auth.uid()))
with check (exists (select 1 from public.workspaces w where w.id = workspace_id and w.owner_user_id = auth.uid()));

create policy coaching_sessions_owner on public.coaching_sessions for all to authenticated
using (exists (select 1 from public.workspaces w where w.id = workspace_id and w.owner_user_id = auth.uid()))
with check (exists (select 1 from public.workspaces w where w.id = workspace_id and w.owner_user_id = auth.uid()));

create policy court_bookings_owner on public.court_bookings for all to authenticated
using (exists (select 1 from public.workspaces w where w.id = workspace_id and w.owner_user_id = auth.uid()))
with check (exists (select 1 from public.workspaces w where w.id = workspace_id and w.owner_user_id = auth.uid()));

create policy social_sessions_owner on public.social_sessions for all to authenticated
using (exists (select 1 from public.workspaces w where w.id = workspace_id and w.owner_user_id = auth.uid()))
with check (exists (select 1 from public.workspaces w where w.id = workspace_id and w.owner_user_id = auth.uid()));

create policy hidden_weeks_owner on public.student_hidden_weeks for all to authenticated
using (exists (select 1 from public.students s join public.workspaces w on w.id = s.workspace_id where s.id = student_id and w.owner_user_id = auth.uid()))
with check (exists (select 1 from public.students s join public.workspaces w on w.id = s.workspace_id where s.id = student_id and w.owner_user_id = auth.uid()));

create policy coaching_session_students_owner on public.coaching_session_students for all to authenticated
using (exists (select 1 from public.coaching_sessions cs join public.workspaces w on w.id = cs.workspace_id where cs.id = session_id and w.owner_user_id = auth.uid()))
with check (
  exists (select 1 from public.coaching_sessions cs join public.workspaces w on w.id = cs.workspace_id where cs.id = session_id and w.owner_user_id = auth.uid())
  and exists (select 1 from public.students s join public.workspaces w on w.id = s.workspace_id where s.id = student_id and w.owner_user_id = auth.uid())
);

create policy social_session_students_owner on public.social_session_students for all to authenticated
using (exists (select 1 from public.social_sessions ss join public.workspaces w on w.id = ss.workspace_id where ss.id = session_id and w.owner_user_id = auth.uid()))
with check (
  exists (select 1 from public.social_sessions ss join public.workspaces w on w.id = ss.workspace_id where ss.id = session_id and w.owner_user_id = auth.uid())
  and exists (select 1 from public.students s join public.workspaces w on w.id = s.workspace_id where s.id = student_id and w.owner_user_id = auth.uid())
);

create policy hidden_people_owner on public.social_hidden_people for all to authenticated
using (exists (select 1 from public.social_sessions ss join public.workspaces w on w.id = ss.workspace_id where ss.id = social_session_id and w.owner_user_id = auth.uid()))
with check (exists (select 1 from public.social_sessions ss join public.workspaces w on w.id = ss.workspace_id where ss.id = social_session_id and w.owner_user_id = auth.uid()));

create policy attendance_owner on public.social_attendance for all to authenticated
using (exists (select 1 from public.social_sessions ss join public.workspaces w on w.id = ss.workspace_id where ss.id = social_session_id and w.owner_user_id = auth.uid()))
with check (exists (select 1 from public.social_sessions ss join public.workspaces w on w.id = ss.workspace_id where ss.id = social_session_id and w.owner_user_id = auth.uid()));
