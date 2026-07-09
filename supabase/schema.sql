-- Chemin de fer — migration Supabase
-- À coller intégralement dans Supabase > SQL Editor > New query, puis "Run".

create extension if not exists pgcrypto;

-- ---- Tables ---------------------------------------------------------

create table if not exists public.issues (
  id uuid primary key default gen_random_uuid(),
  numero text not null default '',
  bouclage date,
  created_at timestamptz not null default now()
);

create table if not exists public.pages (
  id uuid primary key default gen_random_uuid(),
  issue_id uuid not null references public.issues(id) on delete cascade,
  n int not null check (n between 1 and 56),
  rubrique text not null default '',
  sujet text not null default '',
  calib numeric,
  unite text not null default 'signes',
  rendu date,
  statut text not null default 'a_caler',
  notes text not null default '',
  unique (issue_id, n)
);

-- ---- Row Level Security ---------------------------------------------

alter table public.issues enable row level security;
alter table public.pages enable row level security;

drop policy if exists "authenticated read issues" on public.issues;
drop policy if exists "authenticated insert issues" on public.issues;
drop policy if exists "authenticated update issues" on public.issues;
drop policy if exists "authenticated delete issues" on public.issues;

create policy "authenticated read issues" on public.issues
  for select to authenticated using (true);
create policy "authenticated insert issues" on public.issues
  for insert to authenticated with check (true);
create policy "authenticated update issues" on public.issues
  for update to authenticated using (true) with check (true);
create policy "authenticated delete issues" on public.issues
  for delete to authenticated using (true);

drop policy if exists "authenticated read pages" on public.pages;
drop policy if exists "authenticated insert pages" on public.pages;
drop policy if exists "authenticated update pages" on public.pages;
drop policy if exists "authenticated delete pages" on public.pages;

create policy "authenticated read pages" on public.pages
  for select to authenticated using (true);
create policy "authenticated insert pages" on public.pages
  for insert to authenticated with check (true);
create policy "authenticated update pages" on public.pages
  for update to authenticated using (true) with check (true);
create policy "authenticated delete pages" on public.pages
  for delete to authenticated using (true);

-- ---- Realtime ---------------------------------------------------------
-- Permet à Supabase Realtime de diffuser les changements de ces deux tables.

alter publication supabase_realtime add table public.issues;
alter publication supabase_realtime add table public.pages;
