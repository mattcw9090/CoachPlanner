-- Make relationship-only edits visible to CoachPlanner's optimistic sync.
-- Safe to run repeatedly.

begin;

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
create trigger coaching_session_students_touch_parent
after insert or update or delete on coaching_session_students
for each row execute function touch_coaching_session_from_link();

drop trigger if exists social_session_students_touch_parent on social_session_students;
create trigger social_session_students_touch_parent
after insert or update or delete on social_session_students
for each row execute function touch_social_session_from_link();

drop trigger if exists social_hidden_people_touch_parent on social_hidden_people;
create trigger social_hidden_people_touch_parent
after insert or update or delete on social_hidden_people
for each row execute function touch_social_session_from_link();

drop trigger if exists social_attendance_touch_parent on social_attendance;
create trigger social_attendance_touch_parent
after insert or update or delete on social_attendance
for each row execute function touch_social_session_from_link();

drop trigger if exists student_hidden_weeks_touch_parent on student_hidden_weeks;
create trigger student_hidden_weeks_touch_parent
after insert or update or delete on student_hidden_weeks
for each row execute function touch_student_from_hidden_week();

commit;
