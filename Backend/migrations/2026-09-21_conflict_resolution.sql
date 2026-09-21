-- Explicit, reviewed conflict choices only. Ordinary sync remains unchanged.
-- Apply after schema.sql and supabase_policies.sql as the database owner.
-- The function is SECURITY INVOKER: normal authenticated RLS still applies.
-- No expected snapshot or private field values are written to a server log.
begin;

create or replace function public.resolve_coachplanner_conflict(
    p_workspace_id uuid,
    p_table text,
    p_record_id uuid,
    p_expected jsonb,
    p_choice text,
    p_replacement jsonb default null
) returns jsonb
language plpgsql
security invoker
set search_path = pg_catalog, public
set timezone = 'UTC'
as $$
declare
    parent_columns text[];
    relation_tables text[] := array[]::text[];
    relation_columns text[] := array[]::text[];
    mutable_relations text[] := array[]::text[];
    relation_table text;
    relation_column text;
    relation_order text;
    projection text;
    current_record jsonb;
    expected_record jsonb;
    current_rows jsonb;
    expected_rows jsonb;
    snapshot jsonb;
    replacement_record jsonb;
    replacement_rows jsonb;
    row_data jsonb;
    person_id uuid;
    parent_id uuid;
    person_table text;
    found_person uuid;
    assignments text;
    deleting boolean := p_replacement is null or p_replacement = 'null'::jsonb;
    include_incoming boolean := false;
    pass integer;
    i integer;
begin
    if auth.uid() is null or not exists (
        select 1 from public.workspaces
        where id = p_workspace_id and owner_user_id = auth.uid()
    ) then
        raise exception using errcode = '42501', message = 'Workspace is unavailable.';
    end if;
    if p_choice is null or p_choice not in ('device', 'cloud')
        or jsonb_typeof(p_expected) is distinct from 'object'
        or jsonb_typeof(p_expected->'record') is distinct from 'object'
        or jsonb_typeof(p_expected->'relationships') is distinct from 'object' then
        raise exception using errcode = '22023', message = 'Invalid conflict resolution request.';
    end if;

    -- All identifiers below come from this allowlist, never from arbitrary SQL.
    case p_table
    when 'students' then
        parent_columns := array['name','gender','contact_preference','contact_detail','sessions_demand','is_hidden'];
        relation_tables := array['student_hidden_weeks'];
        relation_columns := array['student_id'];
        mutable_relations := relation_tables;
        include_incoming := p_expected->'relationships' ? 'coaching_session_students';
        if include_incoming then
            relation_tables := relation_tables || array['coaching_session_students','social_session_students','social_hidden_people','social_attendance'];
            relation_columns := relation_columns || array['student_id','student_id','student_id','student_id'];
        end if;
    when 'outsiders' then
        parent_columns := array['name','gender','contact_preference','contact_detail'];
        include_incoming := p_expected->'relationships' ? 'social_hidden_people';
        if include_incoming then
            relation_tables := array['social_hidden_people','social_attendance'];
            relation_columns := array['outsider_id','outsider_id'];
        end if;
    when 'coaching_sessions' then
        parent_columns := array['week_start','day_of_week','start_time','end_time','venue','status','court_number','session_fee','session_description'];
        relation_tables := array['coaching_session_students'];
        relation_columns := array['session_id'];
        mutable_relations := relation_tables;
    when 'court_bookings' then
        parent_columns := array['week_start','day_of_week','start_time','end_time','venue','court_number'];
    when 'social_sessions' then
        parent_columns := array['title','week_start','day_of_week','start_time','end_time','venue','status','are_courts_booked','court_numbers','shuttlecock_cost','court_cost'];
        relation_tables := array['social_session_students','social_hidden_people','social_attendance'];
        relation_columns := array['session_id','social_session_id','social_session_id'];
        mutable_relations := relation_tables;
    else
        raise exception using errcode = '22023', message = 'Unsupported conflict record type.';
    end case;

    if p_choice = 'device' and deleting and p_table in ('students','outsiders') and not include_incoming then
        -- Removing a person also removes incoming session/attendance links. They
        -- must be part of the reviewed snapshot, not silently deleted unseen.
        raise exception using errcode = '22023', message = 'Review the person and their linked sessions again before deleting.';
    end if;
    if (select count(*) from jsonb_object_keys(p_expected->'relationships')) <> cardinality(relation_tables)
        or not (p_expected->'relationships' ?& relation_tables) then
        raise exception using errcode = '22023', message = 'The conflict snapshot is incomplete.';
    end if;

    -- Parent row lock serializes with every child trigger. Lock existing child
    -- rows too, so a concurrent multi-request sync cannot silently interleave.
    -- PostgreSQL may abort a competing transaction on deadlock; that is safe to
    -- retry after refreshing the review, never a reason to force a stale choice.
    execute format('select to_jsonb(t) - ''workspace_id'' from public.%I t where id = $1 and workspace_id = $2 for update', p_table)
        into current_record using p_record_id, p_workspace_id;
    if current_record is null then
        raise exception using errcode = '40001', message = 'CP_CONFLICT_STALE: The cloud record changed. Refresh and review it again.';
    end if;
    execute format('select to_jsonb(t) - ''workspace_id'' from jsonb_populate_record(null::public.%I, $1) t', p_table)
        into expected_record using p_expected->'record';
    -- Typed normalization preserves microseconds and accepts equivalent UUID,
    -- numeric, date and timezone spellings; no millisecond tolerance is used.
    if current_record is distinct from expected_record
        or (select count(*) from jsonb_object_keys(p_expected->'record')) <> (select count(*) from jsonb_object_keys(current_record)) then
        raise exception using errcode = '40001', message = 'CP_CONFLICT_STALE: The cloud record changed. Refresh and review it again.';
    end if;

    for pass in 1..2 loop
        snapshot := jsonb_build_object('record', current_record, 'relationships', '{}'::jsonb);
        for i in 1..cardinality(relation_tables) loop
            relation_table := relation_tables[i];
            relation_column := relation_columns[i];
            projection := 'to_jsonb(t)';
            if relation_table in ('coaching_session_students','social_session_students') then
                projection := 'to_jsonb(t) - ''created_at''';
                relation_order := 't.session_id,t.student_id';
            elsif relation_table = 'student_hidden_weeks' then
                relation_order := 't.student_id,t.week_start';
            else
                relation_order := 't.id';
            end if;
            if pass = 1 then
                execute format('select 1 from public.%I where %I = $1 for update', relation_table, relation_column) using p_record_id;
            end if;
            execute format('select coalesce(jsonb_agg(%s order by %s), ''[]''::jsonb) from public.%I t where %I = $1', projection, relation_order, relation_table, relation_column)
                into current_rows using p_record_id;
            if pass = 1 then
                if jsonb_typeof(p_expected->'relationships'->relation_table) is distinct from 'array' then
                    raise exception using errcode = '22023', message = 'The conflict snapshot is incomplete.';
                end if;
                execute format('select coalesce(jsonb_agg(%s order by %s), ''[]''::jsonb) from jsonb_populate_recordset(null::public.%I, $1) t', projection, relation_order, relation_table)
                    into expected_rows using p_expected->'relationships'->relation_table;
                if current_rows is distinct from expected_rows then
                    raise exception using errcode = '40001', message = 'CP_CONFLICT_STALE: Cloud relationships changed. Refresh and review them again.';
                end if;
            end if;
            snapshot := jsonb_set(snapshot, array['relationships',relation_table], current_rows);
        end loop;
        if pass = 2 or p_choice = 'cloud' then
            return snapshot;
        end if;

        if deleting then
            -- Incoming rows are checked above before a person deletion. Their
            -- parent triggers advance affected sessions so other devices pull.
            for i in 1..cardinality(relation_tables) loop
                execute format('delete from public.%I where %I = $1', relation_tables[i], relation_columns[i]) using p_record_id;
            end loop;
            execute format('update public.%I set deleted_at = clock_timestamp() where id = $1 and workspace_id = $2', p_table)
                using p_record_id, p_workspace_id;
        else
            if jsonb_typeof(p_replacement) is distinct from 'object'
                or jsonb_typeof(p_replacement->'record') is distinct from 'object'
                or jsonb_typeof(p_replacement->'relationships') is distinct from 'object'
                or not (p_replacement->'record' ?& parent_columns)
                or (select count(*) from jsonb_object_keys(p_replacement->'record')) <> cardinality(parent_columns)
                or not (p_replacement->'relationships' ?& mutable_relations)
                or (select count(*) from jsonb_object_keys(p_replacement->'relationships')) <> cardinality(mutable_relations) then
                raise exception using errcode = '22023', message = 'The replacement must contain the complete mutable record and its relationships.';
            end if;
            replacement_record := p_replacement->'record';

            -- Validate and lock all dependency people before any mutation. RLS
            -- alone is not enough: one owner may have multiple workspaces.
            foreach relation_table in array mutable_relations loop
                replacement_rows := p_replacement->'relationships'->relation_table;
                if jsonb_typeof(replacement_rows) is distinct from 'array' then
                    raise exception using errcode = '22023', message = 'Replacement relationships must be arrays.';
                end if;
                for row_data in select value from jsonb_array_elements(replacement_rows) loop
                    if jsonb_typeof(row_data) is distinct from 'object' then
                        raise exception using errcode = '22023', message = 'Invalid replacement relationship.';
                    end if;
                    if relation_table = 'student_hidden_weeks' then
                        parent_id := (row_data->>'student_id')::uuid;
                    elsif relation_table in ('coaching_session_students','social_session_students') then
                        parent_id := (row_data->>'session_id')::uuid;
                    else
                        parent_id := (row_data->>'social_session_id')::uuid;
                    end if;
                    if parent_id is distinct from p_record_id then
                        raise exception using errcode = '22023', message = 'A replacement relationship belongs to a different record.';
                    end if;
                    if relation_table = 'student_hidden_weeks' then
                        continue;
                    end if;
                    if relation_table in ('social_hidden_people','social_attendance') and
                        ((row_data->>'student_id') is null) = ((row_data->>'outsider_id') is null) then
                        raise exception using errcode = '22023', message = 'An attendance or hidden-person row must name exactly one person.';
                    end if;
                    if row_data->>'student_id' is not null then
                        person_table := 'students'; person_id := (row_data->>'student_id')::uuid;
                    else
                        person_table := 'outsiders'; person_id := (row_data->>'outsider_id')::uuid;
                    end if;
                    execute format('select id from public.%I where id = $1 and workspace_id = $2 and deleted_at is null for share', person_table)
                        into found_person using person_id, p_workspace_id;
                    if found_person is null then
                        raise exception using errcode = '23503', message = 'A referenced person is missing, deleted, or belongs to another workspace.';
                    end if;
                end loop;
            end loop;

            select string_agg(format('%I = r.%I', column_name, column_name), ', ') into assignments
                from unnest(parent_columns) as column_name;
            execute format('update public.%I t set %s, deleted_at = null from jsonb_populate_record(null::public.%I, $1) r where t.id = $2 and t.workspace_id = $3', p_table, assignments, p_table)
                using replacement_record, p_record_id, p_workspace_id;

            foreach relation_table in array mutable_relations loop
                replacement_rows := p_replacement->'relationships'->relation_table;
                if relation_table = 'student_hidden_weeks' then
                    delete from public.student_hidden_weeks where student_id = p_record_id;
                    insert into public.student_hidden_weeks(student_id,week_start,created_at)
                        select student_id,week_start,coalesce(created_at,now())
                        from jsonb_populate_recordset(null::public.student_hidden_weeks,replacement_rows);
                elsif relation_table = 'coaching_session_students' then
                    delete from public.coaching_session_students where session_id = p_record_id;
                    insert into public.coaching_session_students(session_id,student_id)
                        select session_id,student_id from jsonb_populate_recordset(null::public.coaching_session_students,replacement_rows);
                elsif relation_table = 'social_session_students' then
                    delete from public.social_session_students where session_id = p_record_id;
                    insert into public.social_session_students(session_id,student_id)
                        select session_id,student_id from jsonb_populate_recordset(null::public.social_session_students,replacement_rows);
                elsif relation_table = 'social_hidden_people' then
                    delete from public.social_hidden_people where social_session_id = p_record_id;
                    insert into public.social_hidden_people(id,social_session_id,student_id,outsider_id,created_at)
                        select id,social_session_id,student_id,outsider_id,coalesce(created_at,now())
                        from jsonb_populate_recordset(null::public.social_hidden_people,replacement_rows);
                elsif relation_table = 'social_attendance' then
                    delete from public.social_attendance where social_session_id = p_record_id;
                    insert into public.social_attendance(id,social_session_id,student_id,outsider_id,status,payment_status,created_at)
                        select id,social_session_id,student_id,outsider_id,status,payment_status,coalesce(created_at,now())
                        from jsonb_populate_recordset(null::public.social_attendance,replacement_rows);
                end if;
            end loop;
        end if;
        execute format('select to_jsonb(t) - ''workspace_id'' from public.%I t where id = $1 and workspace_id = $2', p_table)
            into current_record using p_record_id, p_workspace_id;
    end loop;
    raise exception using errcode = 'XX000', message = 'Conflict resolution did not finish.';
end;
$$;

-- Supabase may explicitly grant anon execution through default privileges;
-- revoking PUBLIC alone does not remove that separate grant.
revoke all on function public.resolve_coachplanner_conflict(uuid,text,uuid,jsonb,text,jsonb) from public, anon;
grant execute on function public.resolve_coachplanner_conflict(uuid,text,uuid,jsonb,text,jsonb) to authenticated;

commit;
