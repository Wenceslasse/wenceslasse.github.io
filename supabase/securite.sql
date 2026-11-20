-- Chemin de fer — sécurisation de la base (audit de novembre 2026)
-- À coller intégralement dans Supabase > SQL Editor > New query, puis « Run ».
-- Le script peut être relancé sans risque.
--
-- AVANT de l'exécuter : créez le compte de lecture du mode Équipe dans
-- Authentication > Users > Add user > Create new user
--     Email    : equipe@example.com
--     Password : shazam        (la phrase à compléter sur l'écran de connexion)
--     cochez « Auto Confirm User »
-- (Si vous voulez une autre adresse, remplacez-la ici ET dans index.html,
--  constante VISITOR_EMAIL.)
--
-- Ce que fait ce script :
--  1. une table « membres » dit qui peut lire (lecteur) et qui peut écrire
--     (editeur) ; tous les comptes qui existent déjà deviennent éditeurs, le
--     compte equipe@example.com devient lecteur ;
--  2. plus AUCUNE donnée n'est lisible sans connexion (la clé « anon » est
--     publique : elle figure dans la page) ; un compte créé par quelqu'un
--     d'extérieur ne voit rien non plus tant qu'il n'est pas membre ;
--  3. l'auteur d'une ligne du journal d'activité est fixé par la base (on ne
--     peut plus écrire au nom d'un collègue) ;
--  4. les couleurs personnalisées n'acceptent que des codes #rrggbb.

-- ---- 1. Membres et rôles ----------------------------------------------

create table if not exists public.membres (
  user_id uuid primary key references auth.users(id) on delete cascade,
  email text not null default '',
  role text not null default 'editeur' check (role in ('editeur','lecteur')),
  created_at timestamptz not null default now()
);
alter table public.membres enable row level security;
drop policy if exists "membres : voir sa ligne" on public.membres;
create policy "membres : voir sa ligne" on public.membres
  for select to authenticated using (user_id = (select auth.uid()));

-- Rôle du compte connecté. SECURITY DEFINER : la fonction lit membres sans
-- dépendre des droits de l'appelant, et search_path vide la protège d'un
-- objet homonyme créé ailleurs.
create or replace function public.cdf_role() returns text
  language sql stable security definer set search_path = '' as $$
  select m.role from public.membres m where m.user_id = auth.uid()
$$;
create or replace function public.cdf_lecture() returns boolean
  language sql stable security definer set search_path = '' as $$
  select public.cdf_role() is not null
$$;
create or replace function public.cdf_ecriture() returns boolean
  language sql stable security definer set search_path = '' as $$
  select public.cdf_role() = 'editeur'
$$;
revoke all on function public.cdf_role(), public.cdf_lecture(), public.cdf_ecriture() from public, anon;
grant execute on function public.cdf_role(), public.cdf_lecture(), public.cdf_ecriture() to authenticated;

-- Comptes existants : éditeurs (sauf le compte de lecture).
insert into public.membres (user_id, email, role)
  select u.id, coalesce(u.email,''), 'editeur' from auth.users u
  on conflict (user_id) do nothing;
update public.membres set role = 'lecteur' where lower(email) = 'equipe@example.com';

-- ---- 2. Droits par table ---------------------------------------------
-- On retire TOUTES les policies existantes de ces tables (y compris les
-- lectures « anon » et celles créées à la main dans le tableau de bord),
-- puis on pose les deux seules règles : lire = être membre, écrire = être
-- éditeur.

do $$
declare r record;
begin
  for r in select policyname, tablename from pg_policies
           where schemaname = 'public'
             and tablename in ('issues','pages','color_customizations','activity_log','propositions','page_comments')
  loop
    execute format('drop policy %I on public.%I', r.policyname, r.tablename);
  end loop;
end $$;

do $$
declare t text;
begin
  foreach t in array array['issues','pages','color_customizations','propositions'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy "membres lisent" on public.%I for select to authenticated using ((select public.cdf_lecture()))', t);
    execute format('create policy "editeurs ajoutent" on public.%I for insert to authenticated with check ((select public.cdf_ecriture()))', t);
    execute format('create policy "editeurs modifient" on public.%I for update to authenticated using ((select public.cdf_ecriture())) with check ((select public.cdf_ecriture()))', t);
    execute format('create policy "editeurs suppriment" on public.%I for delete to authenticated using ((select public.cdf_ecriture()))', t);
  end loop;
end $$;

-- Journal : lecture par les membres, ajout par les éditeurs, jamais de
-- modification ni de suppression (append-only).
alter table public.activity_log enable row level security;
create policy "membres lisent" on public.activity_log
  for select to authenticated using ((select public.cdf_lecture()));
create policy "editeurs journalisent" on public.activity_log
  for insert to authenticated with check ((select public.cdf_ecriture()));

-- Ancienne table des commentaires (inutilisée) : fermée.
alter table if exists public.page_comments enable row level security;

-- Le rôle anon n'a plus rien à faire sur ces tables.
revoke all on public.issues, public.pages, public.color_customizations,
              public.activity_log, public.propositions, public.membres from anon;

-- ---- 3. Auteur du journal fixé par la base ----------------------------

create or replace function public.cdf_activity_author() returns trigger
  language plpgsql security definer set search_path = '' as $$
begin
  new.author := coalesce(auth.jwt() ->> 'email', '');
  new.created_at := now();
  return new;
end $$;
drop trigger if exists cdf_activity_author on public.activity_log;
create trigger cdf_activity_author before insert on public.activity_log
  for each row execute function public.cdf_activity_author();

-- ---- 4. Couleurs : codes hexadécimaux uniquement ------------------------
-- « not valid » : la règle s'applique aux nouvelles lignes sans bloquer le
-- script si une ancienne valeur ne la respecte pas (l'application ignore déjà
-- toute couleur mal formée).
alter table public.color_customizations drop constraint if exists couleurs_hex;
alter table public.color_customizations add constraint couleurs_hex
  check (bg_color ~ '^#[0-9A-Fa-f]{6}$' and fg_color ~ '^#[0-9A-Fa-f]{6}$') not valid;

notify pgrst, 'reload schema';

-- ---- Ensuite, dans le tableau de bord (pas en SQL) -----------------------
-- Authentication > Sign In / Providers > Email : décocher « Allow new users
--   to sign up » (personne ne peut plus se créer un compte avec la clé publique).
-- Pour ajouter un rédacteur plus tard : créer son compte dans
--   Authentication > Users, puis exécuter
--     insert into public.membres (user_id, email, role)
--       select id, email, 'editeur' from auth.users where email = 'prenom.nom@exemple.fr'
--       on conflict (user_id) do update set role = 'editeur';
-- Pour retirer un accès : delete from public.membres where email = '…';
