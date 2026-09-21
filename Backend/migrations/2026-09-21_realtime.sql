-- Run with the project's migration/database owner. RLS continues to authorize
-- reads; this publication only enables change notifications for parent records.
-- Relationship triggers in 2026-09-08_relationship_versions.sql notify through
-- their parent rows, so child tables need no separate subscription/publication.
begin;

do $$
declare
    parent_table text;
begin
    if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
        create publication supabase_realtime;
    end if;

    foreach parent_table in array array[
        'students', 'outsiders', 'coaching_sessions', 'court_bookings', 'social_sessions'
    ] loop
        if not exists (
            select 1 from pg_publication_tables
            where pubname = 'supabase_realtime'
              and schemaname = 'public'
              and tablename = parent_table
        ) then
            execute format('alter publication supabase_realtime add table public.%I', parent_table);
        end if;
    end loop;
end
$$;

commit;
