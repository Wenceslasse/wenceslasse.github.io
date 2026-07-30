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

-- ---- Circuit de production éditoriale --------------------------------
-- Cinq jalons par page : livraison V1 (colonne "rendu" existante, dont le sens
-- ne change pas : c'est la date à laquelle le journaliste rend son texte), puis
-- retours de la rédaction en chef, livraison V2, sortie de SR, mise en page.
--
-- Seules les dates SAISIES À LA MAIN sont stockées ; celles qui découlent du
-- rythme du numéro sont calculées côté client et restent nulles en base. Une
-- date non nulle est donc, par définition, une date « figée ».
alter table public.pages add column if not exists d_retours date;
alter table public.pages add column if not exists d_v2 date;
alter table public.pages add column if not exists d_sr date;
alter table public.pages add column if not exists d_agence date;

-- Durée du SR pour cette page : 1 ou 2 jours. NULL = utiliser la valeur par
-- défaut du numéro (issues.r_sr_duree).
alter table public.pages add column if not exists sr_duree smallint check (sr_duree in (1,2));

-- Rythme du numéro : les durées habituelles de la chaîne, réglées une seule
-- fois puis appliquées à tous les dossiers du numéro.
-- Toutes ces durées sont comptées en JOURS OUVRÉS côté application : les
-- retours, le SR et la mise en page ne se font pas le week-end, donc une V1
-- rendue un vendredi n'attend pas de retours le samedi.
alter table public.issues add column if not exists r_retours  smallint not null default 1;  -- V1 → retours
alter table public.issues add column if not exists r_v2       smallint not null default 1;  -- retours → V2
alter table public.issues add column if not exists r_sr_duree smallint not null default 1;  -- V2 → sortie de SR (1 ou 2 j)
alter table public.issues add column if not exists r_agence   smallint not null default 4;  -- sortie de SR → mise en page
alter table public.issues drop constraint if exists issues_r_sr_duree_check;
alter table public.issues add constraint issues_r_sr_duree_check check (r_sr_duree in (1,2));

-- Si les colonnes existaient déjà avec les anciennes valeurs par défaut (3 et 5
-- jours calendaires), « add column if not exists » ne les met pas à jour : on
-- redéclare les défauts explicitement, pour les numéros créés ensuite.
alter table public.issues alter column r_retours set default 1;
alter table public.issues alter column r_v2      set default 1;

-- Réalignement des numéros existants sur le nouveau rythme. La condition porte
-- sur le COUPLE (3, 5), signature d'un rythme jamais personnalisé : un numéro
-- dont vous auriez délibérément réglé ces durées n'est pas touché.
update public.issues set r_retours = 1, r_v2 = 1
 where r_retours = 3 and r_v2 = 5;

-- ---- Vue Matrice : les 12 étapes de validation ------------------------
-- État de chaque étape pour une page : une clé par étape, une valeur parmi
-- ok / encours / afaire / attente / na. Une clé ABSENTE vaut « en attente »,
-- si bien que les pages existantes restent valides sans qu'on écrive rien.
--
-- Dix de ces étapes composent le circuit du texte et se regroupent en les cinq
-- jalons déjà connus (cf. MILESTONES côté application) ; les deux dernières,
-- « playlist » et « icono », forment une piste PARALLÈLE : elles ne jalonnent
-- pas le circuit et ne font pas avancer le statut, mais la maquette en dépend.
alter table public.pages add column if not exists etapes jsonb not null default '{}'::jsonb;

-- N'accepter que les cinq valeurs du vocabulaire.
-- Une contrainte CHECK n'accepte pas de sous-requête : on compare donc le
-- tableau de TOUTES les valeurs — jsonb_path_query_array, qui n'est pas une
-- fonction ensembliste — au vocabulaire autorisé. « <@ » vaut ici « chaque
-- élément de gauche figure à droite », et un objet vide passe sans réserve.
alter table public.pages drop constraint if exists pages_etapes_valides;
alter table public.pages add constraint pages_etapes_valides check (
  jsonb_path_query_array(etapes, '$.*') <@ '["ok","encours","afaire","attente","na"]'::jsonb
);

-- Recherche par étape (« tout ce qui attend un SR final »).
create index if not exists pages_etapes_idx on public.pages using gin (etapes);

-- Les quatre statuts historiques deviennent sept, alignés sur le circuit.
-- « À caler » et « Bouclé » ne changent pas ; « En cours » devient « Écriture »
-- et « Relu » devient « En SR ». Réexécuter ces deux lignes est sans effet :
-- les anciennes valeurs n'existent plus après le premier passage.
update public.pages set statut = 'ecriture' where statut = 'en_cours';
update public.pages set statut = 'sr'       where statut = 'relu';

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

-- Les commentaires par page ont été retirés de l'application. La table
-- public.page_comments n'est volontairement PAS supprimée ici : si elle existe
-- déjà, elle reste en place avec son contenu, simplement inutilisée. La
-- supprimer demanderait un « drop table » explicite, qui détruirait les
-- commentaires déjà saisis.

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
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='activity_log') then
    alter publication supabase_realtime add table public.activity_log;
  end if;
end $$;
