-- Run only through run-atomic-social-sync-tests.sh in a disposable database.
-- Reuse the isolated schema/auth setup and verify the previous RPC regressions.
\ir conflict_resolution.sql
\ir ../migrations/2026-09-24_atomic_social_sync.sql

set role authenticated;
select set_config('request.jwt.claim.sub','10000000-0000-0000-0000-000000000001',false);
insert into students(id,workspace_id,name) values
('91000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000001','Atomic student'),
('91000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000001','Atomic second student'),
('91000000-0000-0000-0000-000000000003','00000000-0000-0000-0000-000000000002','Atomic other workspace');
insert into outsiders(id,workspace_id,name) values
('92000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000001','Atomic guest');

do $$
declare
    workspace uuid := '00000000-0000-0000-0000-000000000001';
    sid uuid := '90000000-0000-0000-0000-000000000001';
    second_id uuid := '90000000-0000-0000-0000-000000000002';
    student uuid := '91000000-0000-0000-0000-000000000001';
    guest uuid := '92000000-0000-0000-0000-000000000001';
    expected jsonb;
    replacement jsonb;
    original_replacement jsonb;
    result jsonb;
    stale jsonb;
    before_snapshot jsonb;
    initial_created timestamptz := '2026-09-01T01:02:03.123456Z';
    attendance_version text;
    child_values jsonb;
begin
    replacement := jsonb_build_object(
        'record', jsonb_build_object('title','Atomic social','week_start','2026-09-21','day_of_week',4,
            'start_time','2026-09-24T09:00:00Z','end_time','2026-09-24T11:00:00Z','venue','Apex','status','Planned',
            'are_courts_booked',false,'court_numbers','1','shuttlecock_cost',10,'court_cost',20),
        'relationships', jsonb_build_object(
            'social_session_students',jsonb_build_array(jsonb_build_object('session_id',sid,'student_id',student)),
            'social_hidden_people',jsonb_build_array(jsonb_build_object('id','93000000-0000-0000-0000-000000000001','social_session_id',sid,'outsider_id',guest,'created_at',initial_created)),
            'social_attendance',jsonb_build_array(jsonb_build_object('id','94000000-0000-0000-0000-000000000001','social_session_id',sid,'student_id',student,
                'status','Pending','payment_status','Unpaid','created_at',initial_created))));
    original_replacement := replacement;
    result := sync_coachplanner_social(workspace,sid,null,replacement,initial_created);
    expected := test_snapshot('social_sessions',sid);
    perform test_assert(result=expected,'Atomic social create returns full committed parent and relationships');
    perform test_assert((result#>>'{record,created_at}')::timestamptz=initial_created,'Atomic create preserves supplied created_at with microseconds');
    select jsonb_build_object('record',s.record,'relationships',s.relationships) into result
        from coachplanner_social_snapshots(workspace) s where id=sid;
    perform test_assert(result=expected,'Single-statement social snapshot matches exact conflict snapshot projection');

    begin
        perform sync_coachplanner_social(workspace,sid,'null',replacement,initial_created);
        raise exception 'FAIL: duplicate create became unchecked upsert';
    exception when serialization_failure then null; end;
    perform test_assert(test_snapshot('social_sessions',sid)=expected,'Lost-response duplicate create is rejected without overwrite');
    begin
        perform sync_coachplanner_social(workspace,second_id,null,null,null);
        raise exception 'FAIL: create/delete ambiguity accepted';
    exception when invalid_parameter_value then null; end;
    perform test_assert(not exists(select 1 from social_sessions where id=second_id),'Null expected and null replacement cannot create a tombstone');

    child_values := expected->'relationships';
    attendance_version := expected#>>'{relationships,social_attendance,0,updated_at}';
    replacement := jsonb_set(replacement,'{record,title}','"Scalar only"');
    -- Cached timestamps may have fewer fractional digits; this is not a new row.
    replacement := jsonb_set(replacement,'{relationships,social_attendance,0,created_at}','"2026-09-01T01:02:03.123Z"');
    replacement := jsonb_set(replacement,'{relationships,social_hidden_people,0,created_at}','"2026-09-01T01:02:03.123Z"');
    result := sync_coachplanner_social(workspace,sid,expected,replacement,null);
    perform test_assert(result#>>'{record,title}'='Scalar only' and result->'relationships'=child_values,
        'Scalar-only update preserves exact child rows and timestamps despite cached timestamp truncation');
    perform test_assert(result#>>'{relationships,social_attendance,0,updated_at}'=attendance_version,
        'Scalar-only update does not rewrite attendance version');
    stale := expected;
    expected := result;
    begin
        perform sync_coachplanner_social(workspace,sid,stale,original_replacement,null);
        raise exception 'FAIL: stale parent accepted';
    exception when serialization_failure then null; end;
    perform test_assert(test_snapshot('social_sessions',sid)=expected,'Stale parent update is rejected without writes');

    replacement := jsonb_set(replacement,'{relationships,social_attendance,0,payment_status}','"Paid"');
    result := sync_coachplanner_social(workspace,sid,expected,replacement,null);
    perform test_assert(result#>>'{relationships,social_attendance,0,payment_status}'='Paid',
        'Attendance/payment update commits with parent in one snapshot');
    perform test_assert(result#>'{relationships,social_hidden_people}'=expected#>'{relationships,social_hidden_people}'
        and result#>'{relationships,social_session_students}'=expected#>'{relationships,social_session_students}',
        'Attendance-only update leaves other relationship collections untouched');
    stale := jsonb_set(expected,'{record}',result->'record');
    expected := result;
    begin
        perform sync_coachplanner_social(workspace,sid,stale,replacement,null);
        raise exception 'FAIL: stale attendance accepted';
    exception when serialization_failure then null; end;
    perform test_assert(test_snapshot('social_sessions',sid)=expected,'Stale child snapshot rejects even with current parent version');

    original_replacement := replacement;
    replacement := jsonb_set(replacement,'{record,title}','"Must roll back"');
    replacement := jsonb_set(replacement,'{relationships,social_session_students,0,student_id}','"91000000-0000-0000-0000-000000000002"');
    replacement := jsonb_set(replacement,'{relationships,social_hidden_people,0,id}','"93000000-0000-0000-0000-000000000002"');
    replacement := jsonb_set(replacement,'{relationships,social_attendance}',
        (replacement#>'{relationships,social_attendance}') || (replacement#>'{relationships,social_attendance}'));
    begin
        perform sync_coachplanner_social(workspace,sid,expected,replacement,null);
        raise exception 'FAIL: late child error accepted';
    exception when unique_violation then null; end;
    perform test_assert(test_snapshot('social_sessions',sid)=expected,'Late attendance failure rolls back parent and both earlier child writes');

    -- The same late failure must not leave a newly created empty social behind.
    replacement := jsonb_set(replacement,'{relationships,social_session_students,0,session_id}',to_jsonb(second_id));
    replacement := jsonb_set(replacement,'{relationships,social_hidden_people,0,social_session_id}',to_jsonb(second_id));
    replacement := jsonb_set(replacement,'{relationships,social_attendance,0,social_session_id}',to_jsonb(second_id));
    replacement := jsonb_set(replacement,'{relationships,social_attendance,1,social_session_id}',to_jsonb(second_id));
    begin
        perform sync_coachplanner_social(workspace,second_id,null,replacement,initial_created);
        raise exception 'FAIL: invalid child create accepted';
    exception when unique_violation then null; end;
    perform test_assert(not exists(select 1 from social_sessions where id=second_id)
        and not exists(select 1 from social_session_students where session_id=second_id)
        and not exists(select 1 from social_hidden_people where social_session_id=second_id),
        'Failed create rolls back parent and every child collection');

    replacement := jsonb_set(original_replacement,'{relationships,social_session_students,0,student_id}','"91000000-0000-0000-0000-000000000003"');
    begin
        perform sync_coachplanner_social(workspace,sid,expected,replacement,null);
        raise exception 'FAIL: cross-workspace person accepted';
    exception when foreign_key_violation then null; end;
    perform test_assert(test_snapshot('social_sessions',sid)=expected,'Cross-workspace dependency rejects even for the same owner');
    replacement := jsonb_set(original_replacement,'{relationships,social_session_students,0,student_id}','"91000000-0000-0000-0000-000000000099"');
    begin
        perform sync_coachplanner_social(workspace,sid,expected,replacement,null);
        raise exception 'FAIL: missing person accepted';
    exception when foreign_key_violation then null; end;
    perform test_assert(test_snapshot('social_sessions',sid)=expected,'Missing person rejects without clearing current attendance');

    -- Aggregate arrays are not independently subject to the API's 500-row page.
    insert into social_attendance(id,social_session_id,student_id,status,payment_status)
        select md5('atomic attendance '||n)::uuid,sid,student,'Pending','Unpaid' from generate_series(1,650) n;
    select jsonb_build_object('record',s.record,'relationships',s.relationships) into result
        from coachplanner_social_snapshots(workspace) s where id=sid;
    perform test_assert(jsonb_array_length(result#>'{relationships,social_attendance}')=651,
        'One coherent snapshot includes all 651 attendance rows without child truncation');
    perform test_assert(result=test_snapshot('social_sessions',sid),'Large-child snapshot preserves deterministic exact ordering');
    perform test_assert((select count(*) from coachplanner_social_snapshots('00000000-0000-0000-0000-000000000003'))=0,
        'Read RPC does not expose another owner workspace');
    perform test_assert((select count(*) from (select id from coachplanner_social_snapshots(workspace) where id=sid order by id limit 1 offset 0) page)=1,
        'Set-returning snapshot supports parent ID filter and pagination');
    begin
        perform sync_coachplanner_social('00000000-0000-0000-0000-000000000003',sid,result,original_replacement,null);
        raise exception 'FAIL: other-owner write accepted';
    exception when insufficient_privilege then null; end;
    perform test_assert(true,'Write RPC rejects another owner workspace');

    expected := result;
    result := sync_coachplanner_social(workspace,sid,expected,null,null);
    perform test_assert(result#>>'{record,deleted_at}' is not null
        and result#>'{relationships,social_session_students}'='[]'::jsonb
        and result#>'{relationships,social_hidden_people}'='[]'::jsonb
        and result#>'{relationships,social_attendance}'='[]'::jsonb,'Atomic delete tombstones parent and removes all relationships');
    perform test_assert(result=test_snapshot('social_sessions',sid),'Delete returns the final complete tombstone snapshot');
    perform test_assert(sync_coachplanner_social(workspace,sid,result,null,null)=result,'Already-confirmed deletion does not rewrite its tombstone');
    insert into social_attendance(id,social_session_id,student_id,status,payment_status)
        values ('94000000-0000-0000-0000-000000000099',sid,student,'Pending','Unpaid');
    result := sync_coachplanner_social(workspace,sid,test_snapshot('social_sessions',sid),null,null);
    perform test_assert(result#>>'{record,deleted_at}' is not null and result#>'{relationships,social_attendance}'='[]'::jsonb,
        'Expected tombstone with legacy leftover children is cleaned atomically without resurrection');
    begin
        perform sync_coachplanner_social(workspace,sid,result,original_replacement,null);
        raise exception 'FAIL: normal sync resurrected a tombstone';
    exception when serialization_failure then null; end;
    perform test_assert(test_snapshot('social_sessions',sid)=result,'Normal sync cannot resurrect a tombstone with a replacement');
    perform set_config('request.jwt.claim.sub','',true);
    perform test_assert((select count(*) from coachplanner_social_snapshots(workspace))=0,'Missing authentication cannot read social snapshots');
    begin
        perform sync_coachplanner_social(workspace,second_id,null,original_replacement,null);
        raise exception 'FAIL: missing auth write accepted';
    exception when insufficient_privilege then null; end;
    perform test_assert(true,'Missing authentication cannot write socials');
end $$;

reset role;
select test_assert(provolatile='s' and not prosecdef,'Snapshot is STABLE and SECURITY INVOKER')
    from pg_proc where oid='public.coachplanner_social_snapshots(uuid)'::regprocedure;
select test_assert(not prosecdef,'Atomic writer is SECURITY INVOKER')
    from pg_proc where oid='public.sync_coachplanner_social(uuid,uuid,jsonb,jsonb,timestamptz)'::regprocedure;
select test_assert(not has_function_privilege('anon',fn,'EXECUTE') and not has_function_privilege('public',fn,'EXECUTE')
    and has_function_privilege('authenticated',fn,'EXECUTE'),'RPC executable only by authenticated clients: '||fn)
    from unnest(array['public.coachplanner_social_snapshots(uuid)','public.sync_coachplanner_social(uuid,uuid,jsonb,jsonb,timestamptz)']) fn;

-- A second connection pauses an actual RPC after its parent UPDATE, before
-- child replacement. The reader must see the old complete snapshot until the
-- entire transaction commits, then the new complete snapshot (never a mix).
create extension dblink;
create function public.test_pause_social_parent() returns trigger language plpgsql as $$
begin
    perform pg_advisory_xact_lock(9242026);
    perform pg_sleep(0.5);
    return new;
end $$;
create trigger test_pause_social_parent after update on public.social_sessions for each row
when (new.id = '90000000-0000-0000-0000-000000000009'::uuid and old.title is distinct from new.title)
execute function public.test_pause_social_parent();

do $$
declare
    workspace uuid := '00000000-0000-0000-0000-000000000001';
    sid uuid := '90000000-0000-0000-0000-000000000009';
    replacement jsonb;
    old_snapshot jsonb;
    during_snapshot jsonb;
    committed_snapshot jsonb;
    returned_snapshot text;
    writer_paused boolean := false;
    n integer;
begin
    replacement := jsonb_build_object('record',jsonb_build_object('title','Pending','week_start','2026-09-21','day_of_week',4,
        'start_time','2026-09-24T09:00:00Z','end_time','2026-09-24T11:00:00Z','venue','Apex','status','Planned',
        'are_courts_booked',false,'court_numbers','1','shuttlecock_cost',10,'court_cost',20),
        'relationships',jsonb_build_object('social_session_students','[]'::jsonb,'social_hidden_people','[]'::jsonb,
        'social_attendance',jsonb_build_array(jsonb_build_object('id','94000000-0000-0000-0000-000000000009',
            'social_session_id',sid,'student_id','91000000-0000-0000-0000-000000000001','status','Pending','payment_status','Unpaid'))));
    -- Create through the second connection so this enclosing DO can observe its
    -- committed initial record before testing the independently updating writer.
    perform dblink_connect('atomic_writer', format('host=%s port=%s dbname=%s user=%s',
        current_setting('unix_socket_directories'),current_setting('port'),current_database(),session_user));
    perform dblink_exec('atomic_writer','set role authenticated');
    perform dblink_exec('atomic_writer','set request.jwt.claim.sub = ''10000000-0000-0000-0000-000000000001''');
    select payload::jsonb into old_snapshot from dblink('atomic_writer',format(
        'select public.sync_coachplanner_social(%L::uuid,%L::uuid,null,%L::jsonb,null)::text',workspace,sid,replacement)) as response(payload text);
    replacement := jsonb_set(replacement,'{record,title}','"Confirmed"');
    replacement := jsonb_set(replacement,'{relationships,social_attendance,0,status}','"Confirmed"');
    perform dblink_send_query('atomic_writer',format(
        'select public.sync_coachplanner_social(%L::uuid,%L::uuid,%L::jsonb,%L::jsonb,null)::text',workspace,sid,old_snapshot,replacement));
    for n in 1..100 loop
        if not pg_try_advisory_lock(9242026) then writer_paused := true; exit; end if;
        perform pg_advisory_unlock(9242026);
        perform pg_sleep(0.01);
    end loop;
    perform test_assert(writer_paused,'Concurrent writer reached an uncommitted parent update before child replacement');
    select jsonb_build_object('record',s.record,'relationships',s.relationships) into during_snapshot
        from coachplanner_social_snapshots(workspace) s where id=sid;
    perform test_assert(during_snapshot=old_snapshot,'Concurrent read sees the previous complete snapshot while atomic write is in flight');
    select payload into returned_snapshot from dblink_get_result('atomic_writer') as response(payload text);
    select jsonb_build_object('record',s.record,'relationships',s.relationships) into committed_snapshot
        from coachplanner_social_snapshots(workspace) s where id=sid;
    perform test_assert(committed_snapshot=returned_snapshot::jsonb
        and committed_snapshot#>>'{record,title}'='Confirmed'
        and committed_snapshot#>>'{relationships,social_attendance,0,status}'='Confirmed',
        'Concurrent read sees the new parent and attendance together after atomic commit');
    perform dblink_disconnect('atomic_writer');
end $$;
drop trigger test_pause_social_parent on public.social_sessions;
drop function public.test_pause_social_parent();
