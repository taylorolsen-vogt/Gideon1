begin;

-- ENABLE ROW LEVEL SECURITY does not apply to the table owner role.
-- FORCE ROW LEVEL SECURITY closes that gap: even a query running as the
-- table owner (e.g. a misconfigured connection role, a superuser session,
-- or a future RPC written with the wrong SECURITY context) is still bound
-- by the auth.uid() = user_id policies below. Defense-in-depth only; the
-- authenticated/anon roles used by PostgREST were already subject to RLS.
alter table public.accounts force row level security;
alter table public.projects force row level security;
alter table public.activity_items force row level security;
alter table public.provider_connections force row level security;
alter table public.chat_sessions force row level security;
alter table public.user_model_preferences force row level security;
alter table public.credential_secret_refs force row level security;

commit;
