# Chemin de fer

Outil de planification éditoriale (chemin de fer d'un magazine de 56 pages), partagé en
temps réel pour une petite équipe. Application web statique (aucun serveur), qui utilise
[Supabase](https://supabase.com) pour les données et l'authentification.

Site publié : https://wenceslasse.github.io

## Mise en route (une seule fois)

1. **Base de données** : ouvrir le SQL Editor du projet Supabase et exécuter le contenu de
   [`supabase/schema.sql`](supabase/schema.sql). Ce script crée les tables `issues` et
   `pages`, active les policies RLS (lecture/écriture réservées aux utilisateurs
   authentifiés) et active le Realtime sur ces deux tables.
2. **Authentification** : voir la section « Restreindre l'accès à l'équipe » ci-dessous.
3. **Redirect URL** : dans Supabase, Authentication → URL Configuration, ajouter
   `https://wenceslasse.github.io` aux Redirect URLs autorisées (sinon le lien magique
   renverra une erreur).

## Utilisation

- À la première connexion, un écran de connexion demande un email : un lien magique est
  envoyé, cliquer dessus ouvre l'application déjà connectée.
- Le sélecteur en haut de la barre d'outils permet de choisir un numéro existant ou
  d'en créer un nouveau (« + Nouveau numéro ») ; ses 56 pages vides sont créées
  automatiquement.
- Chaque page se modifie indépendamment : deux personnes peuvent éditer deux pages
  différentes du même numéro en même temps sans écraser le travail de l'autre
  (chaque champ est enregistré individuellement, et les autres postes se mettent à jour
  en direct via Supabase Realtime).

## Restreindre l'accès à l'équipe

Par défaut, Supabase autorise n'importe quel email à créer un compte via lien magique.
Pour n'autoriser que votre équipe :

1. Dans le dashboard Supabase → **Authentication → Sign In / Providers** (ou
   **Authentication → Settings** selon la version), désactiver **« Allow new users to
   sign up »** (Autoriser les nouvelles inscriptions).
   - Une fois désactivé, seuls les emails déjà présents dans **Authentication → Users**
     pourront se connecter via lien magique ; les emails inconnus recevront une erreur.
2. **Inviter un collègue** : Authentication → Users → **Invite user**, saisir son email.
   Supabase lui envoie un email avec un lien : en cliquant dessus, son compte est créé et
   il peut ensuite se connecter normalement via le lien magique de l'application.
3. (Optionnel, plus strict) Pour restreindre en plus par domaine d'email d'équipe, ajouter
   un *Auth Hook* (Postgres function `before_user_created` ou "Restrict signups") qui
   rejette les emails ne finissant pas par `@votre-domaine.fr`. Cette étape est facultative
   si l'invitation manuelle (étape 2) suffit à contrôler qui a accès.

## Déploiement (GitHub Pages)

Le site est un simple `index.html` statique servi à la racine du dépôt
`wenceslasse.github.io` — c'est un dépôt utilisateur GitHub Pages spécial : une fois le
code poussé sur la branche par défaut, GitHub Pages sert automatiquement le contenu à
`https://wenceslasse.github.io` (à vérifier/activer dans Settings → Pages si besoin).

## Structure du dépôt

- `index.html` — l'application (interface + logique Supabase).
- `supabase/schema.sql` — migration SQL (tables + RLS + Realtime) à coller dans le SQL
  Editor de Supabase.
