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
  journaliste text not null default '',
  lot text not null default '',
  notes text not null default '',
  unique (issue_id, n)
);

-- Si la table existait déjà avant l'ajout du champ "journaliste" (migration
-- ultérieure), cette ligne l'ajoute sans toucher aux données existantes.
alter table public.pages add column if not exists journaliste text not null default '';

-- Ajouter le champ "thematique" sans affecter les données existantes
alter table public.pages add column if not exists thematique text not null default '';

-- Ajouter le champ "lot" (Lot 1 à 4) sans affecter les données existantes
alter table public.pages add column if not exists lot text not null default '';

-- Rendre la contrainte d'unicité (issue_id, n) DÉFERRÉE : lors d'un réordonnancement
-- de pages, plusieurs lignes échangent leur numéro « n » dans un même upsert. Avec une
-- contrainte immédiate, l'état transitoire (deux lignes avec le même n pendant la mise à
-- jour) déclenche « duplicate key value violates unique constraint pages_issue_id_n_key ».
-- En la différant, la vérification a lieu à la fin de la transaction, quand l'état est
-- de nouveau cohérent.
alter table public.pages drop constraint if exists pages_issue_id_n_key;
alter table public.pages add constraint pages_issue_id_n_key unique (issue_id, n) deferrable initially deferred;

create table if not exists public.color_customizations (
  id uuid primary key default gen_random_uuid(),
  issue_id uuid not null references public.issues(id) on delete cascade,
  field_type text not null check (field_type in ('rubrique', 'statut', 'lot')),
  tag_name text not null,
  bg_color text not null,
  fg_color text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (issue_id, field_type, tag_name)
);

-- Commentaires par page (fil de discussion attaché à une page)
create table if not exists public.page_comments (
  id uuid primary key default gen_random_uuid(),
  page_id uuid not null references public.pages(id) on delete cascade,
  author text not null default '',
  body text not null,
  created_at timestamptz not null default now()
);
create index if not exists page_comments_page_id_idx on public.page_comments(page_id);

-- Journal d'activité (traçabilité append-only des modifications d'un numéro)
create table if not exists public.activity_log (
  id uuid primary key default gen_random_uuid(),
  issue_id uuid not null references public.issues(id) on delete cascade,
  page_n int,
  author text not null default '',
  summary text not null,
  created_at timestamptz not null default now()
);
create index if not exists activity_log_issue_id_idx on public.activity_log(issue_id, created_at desc);

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

-- Accès visiteur (lecture seule) : le mot de passe + la question de sécurité
-- sont vérifiés côté client avant d'afficher l'application, mais la seule
-- vraie barrière côté base de données est cette policy de lecture publique.
-- Aucune policy d'écriture n'est ajoutée pour le rôle anon : insert/update/
-- delete restent impossibles sans une vraie session authentifiée.
drop policy if exists "anon read issues" on public.issues;
create policy "anon read issues" on public.issues
  for select to anon using (true);

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

drop policy if exists "anon read pages" on public.pages;
create policy "anon read pages" on public.pages
  for select to anon using (true);

alter table public.color_customizations enable row level security;

drop policy if exists "authenticated read color customizations" on public.color_customizations;
drop policy if exists "authenticated insert color customizations" on public.color_customizations;
drop policy if exists "authenticated update color customizations" on public.color_customizations;
drop policy if exists "authenticated delete color customizations" on public.color_customizations;

create policy "authenticated read color customizations" on public.color_customizations
  for select to authenticated using (true);
create policy "authenticated insert color customizations" on public.color_customizations
  for insert to authenticated with check (true);
create policy "authenticated update color customizations" on public.color_customizations
  for update to authenticated using (true) with check (true);
create policy "authenticated delete color customizations" on public.color_customizations
  for delete to authenticated using (true);

drop policy if exists "anon read color customizations" on public.color_customizations;
create policy "anon read color customizations" on public.color_customizations
  for select to anon using (true);

alter table public.page_comments enable row level security;

drop policy if exists "authenticated read comments" on public.page_comments;
drop policy if exists "authenticated insert comments" on public.page_comments;
drop policy if exists "authenticated delete comments" on public.page_comments;

create policy "authenticated read comments" on public.page_comments
  for select to authenticated using (true);
create policy "authenticated insert comments" on public.page_comments
  for insert to authenticated with check (true);
create policy "authenticated delete comments" on public.page_comments
  for delete to authenticated using (true);

-- Les visiteurs (anon) peuvent lire les commentaires mais pas en publier.
drop policy if exists "anon read comments" on public.page_comments;
create policy "anon read comments" on public.page_comments
  for select to anon using (true);

alter table public.activity_log enable row level security;

drop policy if exists "authenticated read activity" on public.activity_log;
drop policy if exists "authenticated insert activity" on public.activity_log;

create policy "authenticated read activity" on public.activity_log
  for select to authenticated using (true);
create policy "authenticated insert activity" on public.activity_log
  for insert to authenticated with check (true);

-- Les visiteurs (anon) peuvent consulter le journal mais pas y écrire.
drop policy if exists "anon read activity" on public.activity_log;
create policy "anon read activity" on public.activity_log
  for select to anon using (true);

-- ---- Realtime ---------------------------------------------------------
-- Permet à Supabase Realtime de diffuser les changements de ces trois tables.
-- (vérifie d'abord si la table est déjà dans la publication, pour pouvoir
-- relancer ce script sans erreur "already member of publication")

do $$
begin
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='issues') then
    alter publication supabase_realtime add table public.issues;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='pages') then
    alter publication supabase_realtime add table public.pages;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='color_customizations') then
    alter publication supabase_realtime add table public.color_customizations;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='page_comments') then
    alter publication supabase_realtime add table public.page_comments;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='activity_log') then
    alter publication supabase_realtime add table public.activity_log;
  end if;
end $$;
