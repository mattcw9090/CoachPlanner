-- Social sync must read and write a parent and its complete relationships as
-- one database snapshot/transaction. Apply after schema.sql, owner policies,
-- and 2026-09-21_conflict_resolution.sql. No app data is changed by deployment.
begin;

create or replace function public.coachplanner_social_snapshots(p_workspace_id uuid)
returns table(id uuid, record jsonb, relationships jsonb)
language sql stable
security invoker
set search_path = pg_catalog, public
set timezone = 'UTC'
as $$
    select s.id, to_jsonb(s) - 'workspace_id',
        jsonb_build_object(
            'social_session_students', (
                select coalesce(jsonb_agg(to_jsonb(t) - 'created_at' order by t.session_id,t.student_id), '[]'::jsonb)
                from public.social_session_students t where t.session_id = s.id
            ),
            'social_hidden_people', (
                select coalesce(jsonb_agg(to_jsonb(t) order by t.id), '[]'::jsonb)
                from public.social_hidden_people t where t.social_session_id = s.id
            ),
            'social_attendance', (
                select coalesce(jsonb_agg(to_jsonb(t) order by t.id), '[]'::jsonb)
                from public.social_attendance t where t.social_session_id = s.id
            )
        )
    from public.social_sessions s
    where s.workspace_id = p_workspace_id
      and exists (
          select 1 from public.workspaces w
          where w.id = p_workspace_id and w.owner_user_id = auth.uid()
      );
$$;

create or replace function public.sync_coachplanner_social(
    p_workspace_id uuid,
    p_record_id uuid,
    p_expected jsonb,
    p_replacement jsonb,
    p_created_at timestamptz default null
) returns jsonb
language plpgsql
security invoker
set search_path = pg_catalog, public
set timezone = 'UTC'
as $$
declare
    parent_columns constant text[] := array['title','week_start','day_of_week','start_time','end_time','venue','status','are_courts_booked','court_numbers','shuttlecock_cost','court_cost'];
    relation_tables constant text[] := array['social_session_students','social_hidden_people','social_attendance'];
    creating boolean := p_expected is null or p_expected = 'null'::jsonb;
    deleting boolean := p_replacement is null or p_replacement = 'null'::jsonb;
    current_snapshot jsonb;
    current_record public.social_sessions;
    replacement_record public.social_sessions;
    replacement_rows jsonb;
    row_data jsonb;
    relation_table text;
    relation_projection text;
    relation_order text;
    old_values jsonb;
    new_values jsonb;
    changed_relations text[] := array[]::text[];
    person_table text;
    person_id uuid;
    found_person uuid;
begin
    if auth.uid() is null or not exists (
        select 1 from public.workspaces
        where id = p_workspace_id and owner_user_id = auth.uid()
    ) then
        raise exception using errcode = '42501', message = 'Workspace is unavailable.';
    end if;
    if p_record_id is null or (creating and deleting) then
        raise exception using errcode = '22023', message = 'A social create requires a record and relationships.';
    end if;

    if not creating then
        -- Reuse the exact-snapshot validator and row locks. Its cloud choice
        -- performs no writes; locks remain held by this outer transaction.
        current_snapshot := public.resolve_coachplanner_conflict(
            p_workspace_id, 'social_sessions', p_record_id, p_expected, 'cloud', null
        );
        current_record := jsonb_populate_record(null::public.social_sessions, current_snapshot->'record');
        if deleting then
            if current_record.deleted_at is not null
                and current_snapshot->'relationships'->'social_session_students' = '[]'::jsonb
                and current_snapshot->'relationships'->'social_hidden_people' = '[]'::jsonb
                and current_snapshot->'relationships'->'social_attendance' = '[]'::jsonb then
                return current_snapshot;
            end if;
            return public.resolve_coachplanner_conflict(
                p_workspace_id, 'social_sessions', p_record_id, current_snapshot, 'device', null
            );
        end if;
        if current_record.deleted_at is not null then
            raise exception using errcode = '40001', message = 'CP_CONFLICT_STALE: This social was deleted. Refresh before syncing again.';
        end if;
    end if;

    if jsonb_typeof(p_replacement) is distinct from 'object'
        or jsonb_typeof(p_replacement->'record') is distinct from 'object'
        or jsonb_typeof(p_replacement->'relationships') is distinct from 'object'
        or not (p_replacement->'record' ?& parent_columns)
        or (select count(*) from jsonb_object_keys(p_replacement->'record')) <> cardinality(parent_columns)
        or not (p_replacement->'relationships' ?& relation_tables)
        or (select count(*) from jsonb_object_keys(p_replacement->'relationships')) <> cardinality(relation_tables) then
        raise exception using errcode = '22023', message = 'Social sync requires the complete mutable record and all three relationship arrays.';
    end if;
    replacement_record := jsonb_populate_record(null::public.social_sessions, p_replacement->'record');

    -- Validate before any writes, including same-workspace ownership and live
    -- people. FOR SHARE prevents a referenced person's concurrent soft delete.
    foreach relation_table in array relation_tables loop
        replacement_rows := p_replacement->'relationships'->relation_table;
        if jsonb_typeof(replacement_rows) is distinct from 'array' then
            raise exception using errcode = '22023', message = 'Social relationships must be complete arrays.';
        end if;
        for row_data in select value from jsonb_array_elements(replacement_rows) loop
            if jsonb_typeof(row_data) is distinct from 'object'
                or (case when relation_table = 'social_session_students' then row_data->>'session_id'
                         else row_data->>'social_session_id' end)::uuid is distinct from p_record_id then
                raise exception using errcode = '22023', message = 'A social relationship belongs to a different record.';
            end if;
            if relation_table <> 'social_session_students' and
                ((row_data->>'student_id') is null) = ((row_data->>'outsider_id') is null) then
                raise exception using errcode = '22023', message = 'A social relationship must name exactly one person.';
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

        -- Compare meaningful, typed values, not child metadata timestamps. Date
        -- precision lost in the offline cache must not recreate unchanged rows.
        if relation_table = 'social_session_students' then
            relation_projection := 'to_jsonb(t) - ''created_at''';
            relation_order := 't.session_id,t.student_id';
        elsif relation_table = 'social_hidden_people' then
            relation_projection := 'to_jsonb(t) - ''created_at''';
            relation_order := 't.id';
        else
            relation_projection := 'to_jsonb(t) - array[''created_at'',''updated_at'']';
            relation_order := 't.id';
        end if;
        execute format('select coalesce(jsonb_agg(%s order by %s), ''[]''::jsonb) from jsonb_populate_recordset(null::public.%I,$1) t', relation_projection, relation_order, relation_table)
            into new_values using replacement_rows;
        if creating then
            old_values := '[]'::jsonb;
        else
            execute format('select coalesce(jsonb_agg(%s order by %s), ''[]''::jsonb) from jsonb_populate_recordset(null::public.%I,$1) t', relation_projection, relation_order, relation_table)
                into old_values using current_snapshot->'relationships'->relation_table;
        end if;
        if old_values is distinct from new_values then
            changed_relations := array_append(changed_relations, relation_table);
        end if;
    end loop;

    if creating then
        begin
            insert into public.social_sessions(
                id, workspace_id, title, week_start, day_of_week, start_time, end_time,
                venue, status, are_courts_booked, court_numbers, shuttlecock_cost, court_cost, created_at
            ) values (
                p_record_id, p_workspace_id, replacement_record.title, replacement_record.week_start,
                replacement_record.day_of_week, replacement_record.start_time, replacement_record.end_time,
                replacement_record.venue, replacement_record.status, replacement_record.are_courts_booked,
                replacement_record.court_numbers, replacement_record.shuttlecock_cost, replacement_record.court_cost,
                coalesce(p_created_at, now())
            );
        exception when unique_violation then
            -- A lost successful response must be reconciled by a coherent read,
            -- not retried as an unchecked upsert over another device's changes.
            raise exception using errcode = '40001', message = 'CP_CONFLICT_STALE: This social already exists. Refresh before syncing again.';
        end;
    else
        update public.social_sessions set
            title = replacement_record.title, week_start = replacement_record.week_start,
            day_of_week = replacement_record.day_of_week, start_time = replacement_record.start_time,
            end_time = replacement_record.end_time, venue = replacement_record.venue,
            status = replacement_record.status, are_courts_booked = replacement_record.are_courts_booked,
            court_numbers = replacement_record.court_numbers, shuttlecock_cost = replacement_record.shuttlecock_cost,
            court_cost = replacement_record.court_cost
        where id = p_record_id and workspace_id = p_workspace_id;
    end if;

    foreach relation_table in array changed_relations loop
        replacement_rows := p_replacement->'relationships'->relation_table;
        if relation_table = 'social_session_students' then
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
    select jsonb_build_object('record', s.record, 'relationships', s.relationships)
        into current_snapshot from public.coachplanner_social_snapshots(p_workspace_id) s where s.id = p_record_id;
    return current_snapshot;
end;
$$;

-- Supabase's explicit anon default grants are separate from PUBLIC grants.
revoke all on function public.coachplanner_social_snapshots(uuid) from public, anon;
revoke all on function public.sync_coachplanner_social(uuid,uuid,jsonb,jsonb,timestamptz) from public, anon;
grant execute on function public.coachplanner_social_snapshots(uuid) to authenticated;
grant execute on function public.sync_coachplanner_social(uuid,uuid,jsonb,jsonb,timestamptz) to authenticated;

commit;
