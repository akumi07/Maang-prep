-- MAANG Prep: database setup. Run once in Supabase → SQL Editor → New query → paste → Run.
-- Safe to run again.

-- One row of progress per user.
create table if not exists public.progress (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  email      text,
  name       text not null default '',
  data       jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Who can see everyone's progress.
create table if not exists public.admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  added_at timestamptz not null default now()
);

alter table public.progress enable row level security;
alter table public.admins   enable row level security;   -- no policies: not readable through the API at all

-- true when the signed-in user is in public.admins
create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public
as $$ select exists (select 1 from public.admins where user_id = auth.uid()) $$;
revoke all on function public.is_admin() from public, anon;
grant execute on function public.is_admin() to authenticated;

-- email and updated_at are always set by the server, never trusted from the browser
create or replace function public.progress_stamp()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  new.email      := (select email from auth.users where id = new.user_id);
  new.updated_at := now();
  if tg_op = 'UPDATE' then new.created_at := old.created_at; end if;
  return new;
end $$;
drop trigger if exists progress_stamp on public.progress;
create trigger progress_stamp before insert or update on public.progress
for each row execute function public.progress_stamp();

-- Row-level security: everyone reads/writes only their own row; admins can read all rows.
drop policy if exists "read own or admin" on public.progress;
drop policy if exists "insert own"        on public.progress;
drop policy if exists "update own"        on public.progress;
create policy "read own or admin" on public.progress for select to authenticated
  using (user_id = auth.uid() or public.is_admin());
create policy "insert own" on public.progress for insert to authenticated
  with check (user_id = auth.uid());
create policy "update own" on public.progress for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- Expose only what the site needs (new tables aren't exposed automatically in this project).
revoke all on public.progress from anon;
revoke all on public.admins   from anon, authenticated;
grant select, insert, update on public.progress to authenticated;

-- Live updates for the admin page (Realtime still applies the row-level security rules above).
do $$ begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'progress') then
    alter publication supabase_realtime add table public.progress;
  end if;
end $$;
