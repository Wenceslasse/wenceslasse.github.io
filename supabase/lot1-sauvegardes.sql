-- Chemin de fer — lot 1 : sauvegardes automatiques, corbeille, envoi par email
-- À coller intégralement dans Supabase > SQL Editor > New query, puis « Run ».
-- Prérequis : supabase/securite.sql déjà exécuté (fonctions cdf_ecriture…).
-- Le script peut être relancé sans risque.
--
-- Ce que fait ce script :
--  1. une table « sauvegardes » garde des copies complètes de chaque numéro
--     (en-tête, pages, sujets envisagés, couleurs) ;
--  2. chaque nuit à 3 h (heure de Paris en hiver), une copie de chaque numéro
--     MODIFIÉ depuis la précédente ; 30 jours conservés, puis une par mois
--     pendant un an ;
--  3. un numéro supprimé part d'abord à la corbeille (30 jours) ;
--  4. si une adresse et une clé d'envoi sont configurées, les sauvegardes de
--     la nuit partent aussi par email, en pièces jointes.

create extension if not exists pg_cron;
create extension if not exists pg_net;

-- ---- 1. Tables ------------------------------------------------------------

-- Pas de clé étrangère vers issues : une sauvegarde doit survivre à la
-- suppression de son numéro (c'est le principe de la corbeille).
create table if not exists public.sauvegardes (
  id uuid primary key default gen_random_uuid(),
  issue_id uuid not null,
  numero text not null default '',
  kind text not null default 'manuelle'
    check (kind in ('auto','manuelle','avant_restauration','avant_reinitialisation','corbeille','import')),
  empreinte text not null default '',
  taille int not null default 0,
  auteur text not null default '',
  data jsonb not null,
  created_at timestamptz not null default now()
);
create index if not exists sauvegardes_issue_idx on public.sauvegardes(issue_id, created_at desc);

-- Réglages simples (clé → valeur), modifiables par les éditeurs depuis
-- l'appli : aujourd'hui, l'adresse qui reçoit les sauvegardes.
create table if not exists public.reglages (
  cle text primary key,
  valeur text not null default '',
  updated_at timestamptz not null default now()
);

alter table public.sauvegardes enable row level security;
alter table public.reglages enable row level security;
do $$
declare r record;
begin
  for r in select policyname, tablename from pg_policies
           where schemaname='public' and tablename in ('sauvegardes','reglages') loop
    execute format('drop policy %I on public.%I', r.policyname, r.tablename);
  end loop;
end $$;
-- Sauvegardes : lues par les éditeurs ; écrites uniquement par les fonctions
-- ci-dessous (aucune policy d'écriture directe).
create policy "editeurs lisent" on public.sauvegardes
  for select to authenticated using ((select public.cdf_ecriture()));
create policy "editeurs lisent" on public.reglages
  for select to authenticated using ((select public.cdf_ecriture()));
create policy "editeurs modifient" on public.reglages
  for all to authenticated using ((select public.cdf_ecriture())) with check ((select public.cdf_ecriture()));
revoke all on public.sauvegardes, public.reglages from anon;

-- ---- 2. Faire une sauvegarde ----------------------------------------------
-- kind = 'auto' : ne crée rien si le numéro n'a pas changé depuis sa
-- dernière sauvegarde (même empreinte).
create or replace function public.cdf_sauvegarder(p_issue uuid, p_kind text default 'manuelle')
returns uuid language plpgsql security definer set search_path = '' as $$
declare d jsonb; h text; last_h text; nid uuid;
begin
  -- Appel depuis l'appli : réservé aux éditeurs. Appel par la tâche de nuit
  -- (aucun utilisateur connecté) : autorisé.
  if auth.uid() is not null and not public.cdf_ecriture() then
    raise exception 'Droits insuffisants pour sauvegarder';
  end if;
  select jsonb_build_object(
      'format', 'chemin-de-fer/sauvegarde', 'version', 1,
      'issue', to_jsonb(i),
      'pages', coalesce((select jsonb_agg(to_jsonb(p) order by p.n) from public.pages p where p.issue_id = i.id), '[]'::jsonb),
      'propositions', coalesce((select jsonb_agg(to_jsonb(x) order by x.ordre, x.created_at, x.id) from public.propositions x where x.issue_id = i.id), '[]'::jsonb),
      'couleurs', coalesce((select jsonb_agg(to_jsonb(c) order by c.field_type, c.tag_name) from public.color_customizations c where c.issue_id = i.id), '[]'::jsonb))
    into d from public.issues i where i.id = p_issue;
  if d is null then return null; end if;
  h := md5(d::text);
  if p_kind = 'auto' then
    select s.empreinte into last_h from public.sauvegardes s
      where s.issue_id = p_issue and s.kind <> 'corbeille' order by s.created_at desc limit 1;
    if last_h = h then return null; end if;
  end if;
  insert into public.sauvegardes (issue_id, numero, kind, empreinte, taille, auteur, data)
    values (p_issue, coalesce(d->'issue'->>'numero',''), p_kind, h, octet_length(d::text),
            coalesce(auth.jwt()->>'email', 'sauvegarde automatique'), d)
    returning id into nid;
  return nid;
end $$;

-- ---- 3. Restaurer une sauvegarde ------------------------------------------
-- Remet le numéro EXACTEMENT dans l'état sauvegardé, en une seule
-- transaction. L'état actuel est d'abord sauvegardé (« avant restauration »).
-- Le journal d'activité du numéro n'est pas touché. Restaurer une sauvegarde
-- de la corbeille recrée le numéro supprimé.
create or replace function public.cdf_restaurer(p_id uuid)
returns uuid language plpgsql security definer set search_path = '' as $$
declare s record; d jsonb; iid uuid;
begin
  if not public.cdf_ecriture() then raise exception 'Droits insuffisants pour restaurer'; end if;
  select * into s from public.sauvegardes where id = p_id;
  if not found then raise exception 'Sauvegarde introuvable'; end if;
  d := s.data; iid := (d->'issue'->>'id')::uuid;
  if exists (select 1 from public.issues where id = iid) then
    perform public.cdf_sauvegarder(iid, 'avant_restauration');
    delete from public.pages where issue_id = iid;
    delete from public.propositions where issue_id = iid;
    delete from public.color_customizations where issue_id = iid;
    update public.issues i set
      numero = r.numero, bouclage = r.bouclage, theme = r.theme,
      r_retours = r.r_retours, r_v2 = r.r_v2, r_sr_duree = r.r_sr_duree, r_agence = r.r_agence
      from jsonb_populate_record(null::public.issues, d->'issue') r
      where i.id = iid;
  else
    insert into public.issues select * from jsonb_populate_record(null::public.issues, d->'issue');
  end if;
  insert into public.pages select * from jsonb_populate_recordset(null::public.pages, d->'pages');
  insert into public.propositions select * from jsonb_populate_recordset(null::public.propositions, d->'propositions');
  insert into public.color_customizations select * from jsonb_populate_recordset(null::public.color_customizations, d->'couleurs');
  -- Un numéro sorti de la corbeille n'y figure plus.
  delete from public.sauvegardes where issue_id = iid and kind = 'corbeille';
  insert into public.activity_log (issue_id, summary)
    values (iid, 'a restauré la sauvegarde du ' || to_char(s.created_at at time zone 'Europe/Paris', 'DD/MM/YYYY à HH24:MI'));
  return iid;
end $$;

-- ---- 4. Corbeille : sauvegarde automatique avant suppression ---------------
create or replace function public.cdf_corbeille() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform public.cdf_sauvegarder(old.id, 'corbeille');
  return old;
end $$;
drop trigger if exists cdf_corbeille on public.issues;
create trigger cdf_corbeille before delete on public.issues
  for each row execute function public.cdf_corbeille();

-- ---- 5. Envoi par email (Resend) -------------------------------------------
-- La clé d'envoi est rangée dans le coffre-fort de Supabase (Vault), jamais
-- dans une table lisible. Voir l'étape 3 du guide pour l'y ajouter.
create or replace function public.cdf_envoyer_sauvegardes(p_ids uuid[])
returns void language plpgsql security definer set search_path = '' as $$
declare k text; dest text; att jsonb; n int; lst text;
begin
  select valeur into dest from public.reglages where cle = 'sauvegarde_email';
  begin
    select decrypted_secret into k from vault.decrypted_secrets where name = 'resend_api_key' limit 1;
  exception when others then k := null;
  end;
  if coalesce(k,'') = '' or coalesce(dest,'') = '' or coalesce(array_length(p_ids,1),0) = 0 then return; end if;
  select jsonb_agg(jsonb_build_object(
           'filename', regexp_replace(lower(coalesce(nullif(s.numero,''),'numero')), '[^a-z0-9]+', '-', 'g')
                       || '-' || to_char(s.created_at at time zone 'Europe/Paris', 'YYYY-MM-DD') || '.json',
           'content', replace(encode(convert_to(s.data::text, 'UTF8'), 'base64'), E'\n', ''))),
         count(*),
         string_agg('<li>' || replace(replace(s.numero,'<','&lt;'),'>','&gt;') || '</li>', '' order by s.numero)
    into att, n, lst
    from public.sauvegardes s where s.id = any(p_ids);
  if n = 0 then return; end if;
  perform net.http_post(
    url := 'https://api.resend.com/emails',
    headers := jsonb_build_object('Authorization', 'Bearer ' || k, 'Content-Type', 'application/json'),
    body := jsonb_build_object(
      'from', 'Chemin de fer <onboarding@resend.dev>',
      'to', jsonb_build_array(dest),
      'subject', 'Chemin de fer · sauvegarde du ' || to_char(now() at time zone 'Europe/Paris', 'DD/MM/YYYY') || ' (' || n || ' numéro' || case when n > 1 then 's' else '' end || ')',
      'html', '<p>Bonjour,</p><p>Voici la sauvegarde de cette nuit des numéros modifiés hier :</p><ul>' || lst ||
              '</ul><p>Chaque pièce jointe se réimporte dans l''application : menu ⋯ → Sauvegardes → Importer un fichier.</p><p>— Chemin de fer</p>',
      'attachments', att),
    timeout_milliseconds := 20000);
end $$;

-- ---- 6. La tâche de nuit ------------------------------------------------------
create or replace function public.cdf_sauvegarde_nuit()
returns int language plpgsql security definer set search_path = '' as $$
declare r record; nid uuid; ids uuid[] := '{}';
begin
  for r in select id from public.issues loop
    nid := public.cdf_sauvegarder(r.id, 'auto');
    if nid is not null then ids := ids || nid; end if;
  end loop;
  -- Conservation : tout pendant 30 jours ; au-delà, la première sauvegarde de
  -- chaque mois pendant un an ; corbeille vidée après 30 jours.
  delete from public.sauvegardes s
   where s.kind <> 'corbeille' and s.created_at < now() - interval '30 days'
     and (s.created_at < now() - interval '365 days'
          or s.id <> (select s2.id from public.sauvegardes s2
                       where s2.issue_id = s.issue_id and s2.kind <> 'corbeille'
                         and date_trunc('month', s2.created_at) = date_trunc('month', s.created_at)
                       order by s2.created_at limit 1));
  delete from public.sauvegardes where kind = 'corbeille' and created_at < now() - interval '30 days';
  perform public.cdf_envoyer_sauvegardes(ids);
  return coalesce(array_length(ids,1),0);
end $$;

-- Droits : l'appli peut sauvegarder et restaurer (contrôle des droits dans les
-- fonctions) ; la tâche de nuit et l'envoi ne sont pas appelables depuis l'appli.
revoke all on function public.cdf_sauvegarder(uuid, text), public.cdf_restaurer(uuid),
  public.cdf_corbeille(), public.cdf_envoyer_sauvegardes(uuid[]), public.cdf_sauvegarde_nuit() from public, anon, authenticated;
grant execute on function public.cdf_sauvegarder(uuid, text), public.cdf_restaurer(uuid) to authenticated;

-- Chaque nuit à 2 h UTC (3 h à Paris en hiver, 4 h en été).
select cron.schedule('chemin-de-fer-sauvegarde-nuit', '0 2 * * *', 'select public.cdf_sauvegarde_nuit()');

-- Première sauvegarde de tous les numéros, tout de suite.
select public.cdf_sauvegarde_nuit() as numeros_sauvegardes;

notify pgrst, 'reload schema';
