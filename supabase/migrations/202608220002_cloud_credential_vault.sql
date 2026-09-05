begin;

create extension if not exists supabase_vault with schema vault;

create table if not exists public.credential_secret_refs (
    user_id uuid not null references auth.users(id) on delete cascade,
    owner_id text not null,
    secret_kind text not null,
    vault_secret_id uuid not null unique,
    updated_at timestamptz not null default now(),
    primary key (user_id, owner_id, secret_kind)
);

alter table public.credential_secret_refs enable row level security;
revoke all on public.credential_secret_refs from anon, authenticated;

create or replace function public.gideon_cleanup_vault_secret()
returns trigger
language plpgsql
security definer
set search_path = public, vault, pg_temp
as $$
begin
    delete from vault.secrets where id = old.vault_secret_id;
    return old;
end;
$$;

revoke all on function public.gideon_cleanup_vault_secret() from public, anon, authenticated;

drop trigger if exists credential_secret_refs_cleanup on public.credential_secret_refs;
create trigger credential_secret_refs_cleanup
after delete on public.credential_secret_refs
for each row execute function public.gideon_cleanup_vault_secret();

create or replace function public.gideon_upsert_credential_secret(
    p_owner_id text,
    p_secret_kind text,
    p_secret_value text
)
returns void
language plpgsql
security definer
set search_path = public, vault, pg_temp
as $$
declare
    caller_id uuid := auth.uid();
    existing_secret_id uuid;
    created_secret_id uuid;
begin
    if caller_id is null then
        raise exception 'Authentication required';
    end if;
    if nullif(trim(p_owner_id), '') is null
       or nullif(trim(p_secret_kind), '') is null
       or nullif(p_secret_value, '') is null then
        raise exception 'Owner, kind, and secret are required';
    end if;

    select vault_secret_id
      into existing_secret_id
      from public.credential_secret_refs
     where user_id = caller_id
       and owner_id = p_owner_id
       and secret_kind = p_secret_kind
     for update;

    if existing_secret_id is not null then
        update vault.secrets
           set secret = p_secret_value
         where id = existing_secret_id;

        update public.credential_secret_refs
           set updated_at = now()
         where user_id = caller_id
           and owner_id = p_owner_id
           and secret_kind = p_secret_kind;
        return;
    end if;

    select vault.create_secret(
        p_secret_value,
        format('gideon:%s:%s:%s', caller_id, p_owner_id, p_secret_kind),
        'Gideon synchronized provider credential'
    ) into created_secret_id;

    insert into public.credential_secret_refs (
        user_id,
        owner_id,
        secret_kind,
        vault_secret_id
    ) values (
        caller_id,
        p_owner_id,
        p_secret_kind,
        created_secret_id
    );
end;
$$;

create or replace function public.gideon_get_credential_secrets()
returns table (
    owner_id text,
    secret_kind text,
    secret_value text
)
language sql
security definer
set search_path = public, vault, pg_temp
stable
as $$
    select refs.owner_id,
           refs.secret_kind,
           secrets.decrypted_secret
      from public.credential_secret_refs as refs
      join vault.decrypted_secrets as secrets
        on secrets.id = refs.vault_secret_id
     where refs.user_id = auth.uid();
$$;

create or replace function public.gideon_delete_credential_secret(
    p_owner_id text,
    p_secret_kind text
)
returns void
language plpgsql
security definer
set search_path = public, vault, pg_temp
as $$
begin
    if auth.uid() is null then
        raise exception 'Authentication required';
    end if;

    delete from public.credential_secret_refs
     where user_id = auth.uid()
       and owner_id = p_owner_id
       and secret_kind = p_secret_kind;
end;
$$;

revoke all on function public.gideon_upsert_credential_secret(text, text, text) from public, anon;
revoke all on function public.gideon_get_credential_secrets() from public, anon;
revoke all on function public.gideon_delete_credential_secret(text, text) from public, anon;

grant execute on function public.gideon_upsert_credential_secret(text, text, text) to authenticated;
grant execute on function public.gideon_get_credential_secrets() to authenticated;
grant execute on function public.gideon_delete_credential_secret(text, text) to authenticated;

commit;
