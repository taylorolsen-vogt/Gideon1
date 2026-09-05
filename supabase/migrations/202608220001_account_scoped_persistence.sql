begin;

create table if not exists public.accounts (
    user_id uuid not null references auth.users(id) on delete cascade,
    id uuid not null,
    name text not null,
    service text not null,
    auth_type text not null,
    base_url text not null default '',
    notes text not null default '',
    added_at timestamptz not null default now()
);

create table if not exists public.projects (
    user_id uuid not null references auth.users(id) on delete cascade,
    id uuid not null,
    name text not null,
    detail text not null default '',
    summary text,
    stage text not null default 'active',
    group_name text,
    source text not null default 'Gideon',
    created_at timestamptz not null default now()
);

create table if not exists public.activity_items (
    user_id uuid not null references auth.users(id) on delete cascade,
    id uuid not null,
    title text not null,
    detail text not null default '',
    state text not null default 'active',
    source text,
    assignee text,
    project_id uuid,
    created_at timestamptz not null default now()
);

create table if not exists public.provider_connections (
    user_id uuid not null references auth.users(id) on delete cascade,
    id text not null,
    title text not null,
    state text not null,
    detail text not null default '',
    last_updated timestamptz not null default now()
);

create table if not exists public.chat_sessions (
    user_id uuid not null references auth.users(id) on delete cascade,
    id uuid not null,
    title text not null,
    messages_json jsonb not null default '[]'::jsonb,
    is_selected boolean not null default false,
    created_at timestamptz not null default now()
);

create table if not exists public.user_model_preferences (
    user_id uuid not null references auth.users(id) on delete cascade,
    selected_model_id text not null,
    api_profiles_json text not null default '[]',
    updated_at timestamptz not null default now()
);

do $$
declare
    constraint_name text;
begin
    for constraint_name in
        select con.conname
        from pg_constraint con
        join pg_class rel on rel.oid = con.conrelid
        join pg_namespace nsp on nsp.oid = rel.relnamespace
        where nsp.nspname = 'public'
          and rel.relname = 'activity_items'
          and con.contype = 'f'
          and pg_get_constraintdef(con.oid) like '%project_id%'
    loop
        execute format('alter table public.activity_items drop constraint %I', constraint_name);
    end loop;
end
$$;

do $$
declare
    table_name text;
    constraint_name text;
begin
    foreach table_name in array array[
        'accounts',
        'projects',
        'activity_items',
        'provider_connections',
        'chat_sessions',
        'user_model_preferences'
    ]
    loop
        for constraint_name in
            select con.conname
            from pg_constraint con
            join pg_class rel on rel.oid = con.conrelid
            join pg_namespace nsp on nsp.oid = rel.relnamespace
            where nsp.nspname = 'public'
              and rel.relname = table_name
              and con.contype = 'p'
        loop
            execute format('alter table public.%I drop constraint %I', table_name, constraint_name);
        end loop;
    end loop;
end
$$;

alter table public.accounts
    add primary key (user_id, id);

alter table public.projects
    add primary key (user_id, id);

alter table public.activity_items
    add primary key (user_id, id);

alter table public.provider_connections
    add primary key (user_id, id);

alter table public.chat_sessions
    add primary key (user_id, id);

alter table public.user_model_preferences
    add primary key (user_id);

do $$
begin
    if exists (
        select 1
        from information_schema.columns
        where table_schema = 'public'
          and table_name = 'activity_items'
          and column_name = 'project_id'
    ) then
        alter table public.activity_items
            add constraint activity_items_project_owner_fk
            foreign key (user_id, project_id)
            references public.projects(user_id, id)
            on delete cascade
            not valid;
    end if;
end
$$;

alter table public.accounts enable row level security;
alter table public.projects enable row level security;
alter table public.activity_items enable row level security;
alter table public.provider_connections enable row level security;
alter table public.chat_sessions enable row level security;
alter table public.user_model_preferences enable row level security;

do $$
declare
    table_name text;
    policy_name text;
begin
    foreach table_name in array array[
        'accounts',
        'projects',
        'activity_items',
        'provider_connections',
        'chat_sessions',
        'user_model_preferences'
    ]
    loop
        for policy_name in
            select policyname
            from pg_policies
            where schemaname = 'public'
              and tablename = table_name
        loop
            execute format('drop policy %I on public.%I', policy_name, table_name);
        end loop;

        execute format(
            'create policy %I on public.%I for select to authenticated using (auth.uid() = user_id)',
            table_name || '_select_own',
            table_name
        );
        execute format(
            'create policy %I on public.%I for insert to authenticated with check (auth.uid() = user_id)',
            table_name || '_insert_own',
            table_name
        );
        execute format(
            'create policy %I on public.%I for update to authenticated using (auth.uid() = user_id) with check (auth.uid() = user_id)',
            table_name || '_update_own',
            table_name
        );
        execute format(
            'create policy %I on public.%I for delete to authenticated using (auth.uid() = user_id)',
            table_name || '_delete_own',
            table_name
        );

        execute format('grant select, insert, update, delete on public.%I to authenticated', table_name);
    end loop;
end
$$;

commit;
