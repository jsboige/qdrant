# Suppression définitive des snapshots Drive — setup OAuth user (Q8-b, 17/11/2026)

## Le problème en 3 lignes

La rétention offsite (keep-3) tournait via le montage DriveFS : chaque rotation partait en
**corbeille** (~30-190 Go/nuit). Sur le forfait One 5 To, la corbeille sature le quota
(corbeille vidée à la main le 17/11 ; saturation projetée ~23/11 sans correctif — RX162).

**Mesuré le 17/11** : faire du service account l'uploader est **impossible** — un SA ne peut
pas posséder de fichiers sur un My Drive consommateur (`403 Storage Quota Exceeded`,
échappatoire = Shared Drives = Workspace, absent ici).

**La solution** : supprimer via l'API Drive **en tant que user** — `files.delete` est une
suppression **définitive, sans corbeille** (comportement documenté Google). L'upload reste
DriveFS (inchangé). Il faut un **refresh token OAuth** du titulaire du Drive : consentement
**une seule fois**, ci-dessous (~5 min au total).

## Gestes user (une seule fois)

### 1. Créer un client OAuth « Application de bureau » (~4 min)

1. Ouvrir <https://console.cloud.google.com/apis/credentials> — projet **`myia-backups`**
   (celui du SA `qdrant-backup-purger@myia-backups.iam.gserviceaccount.com`).
2. Si l'écran demande de configurer l'« Écran de consentement OAuth » d'abord :
   choisir **Externe**, renseigner un nom d'appli (ex. `qdrant-backup-retention`), ajouter
   votre email comme utilisateur test. Pas d'autres champs utiles.
3. **IMPORTANT — publier l'application** : la publication exige d'abord une **page
   d'accueil** et un **lien de confidentialité** sur un **domaine autorisé** — le dépôt
   public sur `github.com` convient (domaine autorisé par défaut ; mesuré 17/11 : page
   d'accueil = <https://github.com/jsboige/roo-extensions>, confidentialité =
   <https://github.com/jsboige/roo-extensions#privacy> — toute URL github.com stable passe).
   Puis écran de consentement → **Audience** (ou « Statut de publication ») → **Publier
   l'application → En production**. Sans cette publication, l'appli reste « En test » et
   **Google fait expirer l'autorisation 7 jours après le consentement** (« Authorizations
   by a test user will expire seven days from the time of consent », aide Google Cloud) —
   le jeton mourrait vers le 24/11 et la rétention retomberait sur la corbeille. La
   publication ne déclenche **aucune** vérification Google : c'est instantané, pour un
   usage personnel.
4. **Créer des identifiants → ID client OAuth → Application de bureau → Créer**.
5. Copier l'**ID client** et le **Secret client** affichés.
6. Les coller dans `myia_qdrant/.gdrive_oauth_client.json` (gitignoré) :

   ```json
   { "client_id": "xxxx.apps.googleusercontent.com", "client_secret": "GOCSPX-xxxx" }
   ```

### 2. Consentir (1 clic)

Demander à la lane qdrant de lancer `myia_qdrant/scripts/utilities/gdrive_oauth_consent.ps1`
(ou le lancer soi-même) : le navigateur s'ouvre sur Google, compte
**jsboige@gmail.com** → **Autoriser**. Deux écrans sont normaux :

- Éventuellement **« Google n'a pas validé cette application »** : cliquer
  **Paramètres avancés → Accéder à [nom de l'appli]**. C'est l'avertissement standard des
  applis personnelles non vérifiées (aucune vérification Google n'a été demandée — elle
  est inutile pour un usage privé, et le fait que VOUS êtes le créateur de l'appli rend
  l'écran purement informatif).
- Puis la demande de permission :

> « Voir, modifier, créer et supprimer définitivement l'intégralité de vos fichiers
> Google Drive »

C'est le wording standard du scope `drive` — nécessaire parce que les snapshots sont
possédés par le compte, pas par l'application. Le refresh token atterrit dans
`myia_qdrant/.gdrive_oauth.json` (gitignoré, jamais imprimé, jamais commité).

### 3. C'est fini

Dès le cycle suivant, `qdrant_snapshot_backup.ps1` détecte le token et supprime les
rotations **définitivement** (log : `Retention (offsite) deleted PERMANENTLY`). Sans token,
comportement legacy (corbeille) + WARN dans le log.

## Sécurité

- Les deux fichiers `.gdrive_oauth*.json` sont **gitignorés** (vérifié dans `.gitignore`).
- Le refresh token peut être révoqué à tout moment : console Google → Sécurité →
  Applications tierces avec accès au compte → retirer `qdrant-backup-retention`.
- La purge de corbeille existante est **chirurgicale** : seuls les items nommés
  `*.snapshot*` sont touchés (`-PurgeTrashSnapshots` liste d'abord, `-Execute` agit ;
  jamais d'`emptyTrash` global — la corbeille n'appartient pas qu'à cette lane).
