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
