-- Run only through run-conflict-resolution-tests.sh in a disposable database.
set timezone = 'UTC';
create role authenticated;
create role anon;
create schema auth;
create function auth.uid() returns uuid language sql stable as
$$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
grant usage on schema auth to authenticated;
grant execute on function auth.uid() to authenticated;
\ir ../schema.sql
\ir ../supabase_policies.sql
-- Reproduce Supabase's explicit anon default grant, independent of PUBLIC.
alter default privileges in schema public grant execute on functions to anon;
\ir ../migrations/2026-09-21_conflict_resolution.sql
grant usage on schema public to authenticated;
grant select,insert,update,delete on all tables in schema public to authenticated;

create function public.test_assert(ok boolean, description text) returns void language plpgsql as $$
begin
    if ok is distinct from true then raise exception 'FAIL: %', description; end if;
    raise notice 'PASS: %', description;
end $$;

-- Independent test reader mirroring the documented PostgREST select columns.
create function public.test_snapshot(tab text, rid uuid, incoming boolean default false) returns jsonb
language plpgsql as $$
declare rec jsonb; rel jsonb := '{}'; rows jsonb;
begin
    execute format('select to_jsonb(t)-''workspace_id'' from public.%I t where id=$1',tab) into rec using rid;
    if tab='students' then
        select coalesce(jsonb_agg(to_jsonb(t) order by student_id,week_start),'[]') into rows from student_hidden_weeks t where student_id=rid;
        rel := rel || jsonb_build_object('student_hidden_weeks',rows);
    end if;
    if tab='coaching_sessions' or (tab='students' and incoming) then
        select coalesce(jsonb_agg(to_jsonb(t)-'created_at' order by session_id,student_id),'[]') into rows from coaching_session_students t where (tab='students' and student_id=rid) or (tab='coaching_sessions' and session_id=rid);
        rel := rel || jsonb_build_object('coaching_session_students',rows);
    end if;
    if tab='social_sessions' or (tab='students' and incoming) then
        select coalesce(jsonb_agg(to_jsonb(t)-'created_at' order by session_id,student_id),'[]') into rows from social_session_students t where (tab='students' and student_id=rid) or (tab='social_sessions' and session_id=rid);
        rel := rel || jsonb_build_object('social_session_students',rows);
    end if;
    if tab='social_sessions' or (tab in ('students','outsiders') and incoming) then
        select coalesce(jsonb_agg(to_jsonb(t) order by id),'[]') into rows from social_hidden_people t where (tab='students' and student_id=rid) or (tab='outsiders' and outsider_id=rid) or (tab='social_sessions' and social_session_id=rid);
        rel := rel || jsonb_build_object('social_hidden_people',rows);
        select coalesce(jsonb_agg(to_jsonb(t) order by id),'[]') into rows from social_attendance t where (tab='students' and student_id=rid) or (tab='outsiders' and outsider_id=rid) or (tab='social_sessions' and social_session_id=rid);
        rel := rel || jsonb_build_object('social_attendance',rows);
    end if;
    return jsonb_build_object('record',rec,'relationships',rel);
end $$;
grant execute on function public.test_snapshot(text,uuid,boolean),public.test_assert(boolean,text) to authenticated;

insert into workspaces(id,owner_user_id) values
('00000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001'),
('00000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000001'),
('00000000-0000-0000-0000-000000000003','10000000-0000-0000-0000-000000000002');
insert into students(id,workspace_id,name) values
('20000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000001','Alice'),
('20000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000001','Bob'),
('20000000-0000-0000-0000-000000000003','00000000-0000-0000-0000-000000000002','Other workspace');
insert into outsiders(id,workspace_id,name) values ('30000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000001','Guest');
insert into coaching_sessions(id,workspace_id,week_start,day_of_week,start_time,end_time,venue) values
('40000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000001','2026-09-21',1,'2026-09-21T09:00:00Z','2026-09-21T10:00:00Z','Apex');
insert into court_bookings(id,workspace_id,week_start,day_of_week,start_time,end_time,venue,court_number) values
('50000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000001','2026-09-21',1,'2026-09-21T09:00:00Z','2026-09-21T10:00:00Z','Apex','1');
insert into social_sessions(id,workspace_id,week_start,day_of_week,start_time,end_time,venue) values
('60000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000001','2026-09-21',1,'2026-09-21T09:00:00Z','2026-09-21T10:00:00Z','Apex');
insert into coaching_session_students(session_id,student_id) values ('40000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001');
insert into student_hidden_weeks(student_id,week_start) values ('20000000-0000-0000-0000-000000000001','2026-09-21');
insert into social_session_students(session_id,student_id) values ('60000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001');
insert into social_hidden_people(id,social_session_id,outsider_id) values ('70000000-0000-0000-0000-000000000001','60000000-0000-0000-0000-000000000001','30000000-0000-0000-0000-000000000001');
insert into social_attendance(id,social_session_id,student_id,status,payment_status) values ('80000000-0000-0000-0000-000000000001','60000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001','Confirmed','Unpaid');

set role authenticated;
select set_config('request.jwt.claim.sub','10000000-0000-0000-0000-000000000001',false);
do $$
declare
    workspace uuid := '00000000-0000-0000-0000-000000000001';
    tables text[] := array['students','outsiders','coaching_sessions','court_bookings','social_sessions'];
    ids uuid[] := array['20000000-0000-0000-0000-000000000001','30000000-0000-0000-0000-000000000001','40000000-0000-0000-0000-000000000001','50000000-0000-0000-0000-000000000001','60000000-0000-0000-0000-000000000001']::uuid[];
    expected jsonb; replacement jsonb; result jsonb; before_snapshot jsonb; changed jsonb;
    i integer;
begin
    for i in 1..5 loop
        expected := test_snapshot(tables[i],ids[i]);
        result := resolve_coachplanner_conflict(workspace,tables[i],ids[i],expected,'cloud');
        perform test_assert(result=expected and result=test_snapshot(tables[i],ids[i]), tables[i] || ': cloud choice checks without writes');
        replacement := jsonb_build_object('record',(expected->'record')-array['id','created_at','updated_at','deleted_at'],'relationships',expected->'relationships');
        if i<=2 then replacement := jsonb_set(replacement,'{record,name}','"Device choice"');
        else replacement := jsonb_set(replacement,'{record,venue}','"TRS"'); end if;
        result := resolve_coachplanner_conflict(workspace,tables[i],ids[i],expected,'device',replacement);
        perform test_assert(result=test_snapshot(tables[i],ids[i]) and result->'record' <> expected->'record', tables[i] || ': device choice returns committed full snapshot');
    end loop;

    expected := test_snapshot('students',ids[1]);
    update students set name='Newer cloud change' where id=ids[1];
    before_snapshot := test_snapshot('students',ids[1]);
    begin
        perform resolve_coachplanner_conflict(workspace,'students',ids[1],expected,'cloud');
        raise exception 'FAIL: stale cloud choice accepted';
    exception when serialization_failure then null; end;
    perform test_assert(test_snapshot('students',ids[1])=before_snapshot,'Stale scalar snapshot rejects without writes');

    -- Two exact instants within one millisecond are not interchangeable.
    expected := test_snapshot('students',ids[1]);
    changed := jsonb_set(expected,'{record,updated_at}',to_jsonb(((expected#>>'{record,updated_at}')::timestamptz + interval '1 microsecond')));
    begin
        perform resolve_coachplanner_conflict(workspace,'students',ids[1],changed,'cloud');
        raise exception 'FAIL: submillisecond version mismatch accepted';
    exception when serialization_failure then null; end;
    perform test_assert(true,'Microsecond cloud version differences reject');
    changed := jsonb_set(expected,'{record,updated_at}',to_jsonb(to_char((expected#>>'{record,updated_at}')::timestamptz at time zone 'Australia/Perth','YYYY-MM-DD"T"HH24:MI:SS.US')||'+08:00'));
    result := resolve_coachplanner_conflict(workspace,'students',ids[1],changed,'cloud');
    perform test_assert(result=expected,'Equivalent timezone representation is accepted');

    expected := test_snapshot('social_sessions',ids[5]);
    update social_attendance set payment_status='Paid' where social_session_id=ids[5];
    -- Retain current parent version to prove children themselves are compared.
    changed := jsonb_set(expected,'{record}',test_snapshot('social_sessions',ids[5])->'record');
    begin
        perform resolve_coachplanner_conflict(workspace,'social_sessions',ids[5],changed,'cloud');
        raise exception 'FAIL: stale child snapshot accepted';
    exception when serialization_failure then null; end;
    perform test_assert(true,'Attendance/payment snapshot differences reject independently of parent timestamp');

    expected := test_snapshot('coaching_sessions',ids[3]);
    replacement := jsonb_build_object('record',(expected->'record')-array['id','created_at','updated_at','deleted_at'],'relationships',expected->'relationships');
    replacement := jsonb_set(replacement,'{relationships,coaching_session_students}',jsonb_build_array(jsonb_build_object('session_id',ids[3],'student_id','20000000-0000-0000-0000-000000000003')));
    begin
        perform resolve_coachplanner_conflict(workspace,'coaching_sessions',ids[3],expected,'device',replacement);
        raise exception 'FAIL: other workspace person accepted';
    exception when foreign_key_violation then null; end;
    perform test_assert(test_snapshot('coaching_sessions',ids[3])=expected,'Same owner, different workspace dependencies reject atomically');
    replacement := jsonb_set(replacement,'{relationships,coaching_session_students}',jsonb_build_array(jsonb_build_object('session_id',ids[3],'student_id','20000000-0000-0000-0000-000000000099')));
    begin
        perform resolve_coachplanner_conflict(workspace,'coaching_sessions',ids[3],expected,'device',replacement);
        raise exception 'FAIL: missing person accepted';
    exception when foreign_key_violation then null; end;
    perform test_assert(test_snapshot('coaching_sessions',ids[3])=expected,'Missing dependencies reject without removing existing memberships');
    update students set deleted_at=now() where id='20000000-0000-0000-0000-000000000002';
    replacement := jsonb_set(replacement,'{relationships,coaching_session_students}',jsonb_build_array(jsonb_build_object('session_id',ids[3],'student_id','20000000-0000-0000-0000-000000000002')));
    begin
        perform resolve_coachplanner_conflict(workspace,'coaching_sessions',ids[3],expected,'device',replacement);
        raise exception 'FAIL: deleted person accepted';
    exception when foreign_key_violation then null; end;
    perform test_assert(test_snapshot('coaching_sessions',ids[3])=expected,'Soft-deleted dependencies reject without writes');

    expected := test_snapshot('social_sessions',ids[5]);
    replacement := jsonb_build_object('record',(expected->'record')-array['id','created_at','updated_at','deleted_at'],'relationships',expected->'relationships');
    replacement := jsonb_set(replacement,'{record,title}','"Must roll back"');
    -- A duplicate primary key fails after parent update and earlier child writes.
    replacement := jsonb_set(replacement,'{relationships,social_attendance}',(replacement#>'{relationships,social_attendance}') || (replacement#>'{relationships,social_attendance}'));
    begin
        perform resolve_coachplanner_conflict(workspace,'social_sessions',ids[5],expected,'device',replacement);
        raise exception 'FAIL: duplicate child accepted';
    exception when unique_violation then null; end;
    perform test_assert(test_snapshot('social_sessions',ids[5])=expected,'Late child failure rolls back parent and all relationship writes');

    begin
        perform resolve_coachplanner_conflict(workspace,'workspaces',workspace,expected,'cloud');
        raise exception 'FAIL: unexpected table accepted';
    exception when invalid_parameter_value then null; end;
    begin
        perform resolve_coachplanner_conflict('00000000-0000-0000-0000-000000000003','students',ids[1],expected,'cloud');
        raise exception 'FAIL: different owner accepted';
    exception when insufficient_privilege then null; end;
    perform test_assert(true,'Arbitrary table and other-owner workspace denied');

    expected := test_snapshot('students',ids[1]);
    begin
        perform resolve_coachplanner_conflict(workspace,'students',ids[1],expected,'device',null);
        raise exception 'FAIL: person deletion without incoming snapshot accepted';
    exception when invalid_parameter_value then null; end;
    perform test_assert(test_snapshot('students',ids[1])=expected,'Person deletion requires reviewed incoming relationships');
    expected := test_snapshot('students',ids[1],true);
    insert into social_attendance(id,social_session_id,student_id,status,payment_status) values
        ('80000000-0000-0000-0000-000000000002',ids[5],ids[1],'Pending','Unpaid');
    before_snapshot := test_snapshot('students',ids[1],true);
    perform test_assert(before_snapshot->'record'=expected->'record','Incoming attendance change does not advance person version');
    begin
        perform resolve_coachplanner_conflict(workspace,'students',ids[1],expected,'device',null);
        raise exception 'FAIL: newly linked attendance silently deleted';
    exception when serialization_failure then null; end;
    perform test_assert(test_snapshot('students',ids[1],true)=before_snapshot,'Person deletion rejects new incoming relationships after review');
    expected := test_snapshot('students',ids[1],true);
    result := resolve_coachplanner_conflict(workspace,'students',ids[1],expected,'device',null);
    perform test_assert(result#>>'{record,deleted_at}' is not null and result=test_snapshot('students',ids[1],true),'Student deletion atomically tombstones and cleans all incoming relationships');
    perform test_assert(not exists(select 1 from social_attendance where student_id=ids[1]) and not exists(select 1 from coaching_session_students where student_id=ids[1]),'Student deletion leaves no dangling attendance or membership');

    expected := test_snapshot('outsiders',ids[2],true);
    result := resolve_coachplanner_conflict(workspace,'outsiders',ids[2],expected,'device','null');
    perform test_assert(result#>>'{record,deleted_at}' is not null and not exists(select 1 from social_hidden_people where outsider_id=ids[2]),'Outsider deletion cleans social relationships');
    for i in 3..5 loop
        expected := test_snapshot(tables[i],ids[i]);
        result := resolve_coachplanner_conflict(workspace,tables[i],ids[i],expected,'device',null);
        perform test_assert(result#>>'{record,deleted_at}' is not null and result=test_snapshot(tables[i],ids[i]),tables[i]||': explicit deletion returns tombstone snapshot');
    end loop;
end $$;

reset role;
select test_assert(not prosecdef,'RPC has no SECURITY DEFINER privilege bypass') from pg_proc where oid='public.resolve_coachplanner_conflict(uuid,text,uuid,jsonb,text,jsonb)'::regprocedure;
select test_assert(not has_function_privilege('public','public.resolve_coachplanner_conflict(uuid,text,uuid,jsonb,text,jsonb)','EXECUTE'),'Anonymous PUBLIC role cannot execute resolution RPC');
select test_assert(not has_function_privilege('anon','public.resolve_coachplanner_conflict(uuid,text,uuid,jsonb,text,jsonb)','EXECUTE'),'Explicit anon default grant is revoked from resolution RPC');
