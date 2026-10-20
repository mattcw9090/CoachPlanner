-- Per-student replies on a coaching session.
-- Safe to run repeatedly. Existing students of a live confirmed session are
-- marked confirmed; every other membership stays pending.
-- Do not infer deletions. This does not add a status-derivation trigger.

begin;

alter table coaching_session_students
    add column if not exists status text not null default 'Pending',
    add column if not exists responded_at timestamptz;

alter table coaching_session_students drop constraint if exists coaching_session_students_status_check;
alter table coaching_session_students
    add constraint coaching_session_students_status_check
    check (status in ('Pending', 'Confirmed', 'Declined'));

update coaching_session_students l
set status = 'Confirmed'
from coaching_sessions s
where s.id = l.session_id
  and s.status = 'Confirmed'
  and s.deleted_at is null
  and l.status <> 'Confirmed';

commit;
