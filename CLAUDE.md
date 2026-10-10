# pgdump-age

Image Docker + script bash qui sauvegarde **une base PostgreSQL 18 (`PGDATABASE`) en un objet S3 compressé et chiffré**, sans fichier local :

```
pg_dump --format=custom --compress=zstd:5 | age --recipient KEY | rclone rcat DEST/<base>-AAAAMMJJTHHMMSSZ.dump.age  +  <nom>.in_progress (progression)  ->  <nom>.ok (valide)
```

Cible : un accessory Kamal (`docker run` avec variables d'environnement), staging d'abord, puis la prod (base d'environ 121 Go, dump de dizaines de Go en flux de taille inconnue). S3 = OVH Object Storage. Le README décrit la configuration et la restauration ; ce fichier fixe les règles de modification.

## Fichiers

- `bin/pgdump-age` : tout le comportement (`schedule`, `once`, `list`, `get`). Copié dans l'image.
- `Dockerfile` : Alpine 3.23, `postgresql18-client`, `age`, `rclone`, `bash`, `tini`, utilisateur non root.
- `test/run.sh`, `test/compose.yml`, `test/init.sql` : test de bout en bout (Docker requis).
- `README.md`, section Kamal : bloc d'accessory, lignes de secrets et SQL du rôle sont en ligne (plus de dossier `examples/`). Le bloc a été validé en rendant la vraie commande `docker run` avec Kamal 2.12 ; à revalider si ces extraits changent.
- `.github/workflows/image.yml` : tests sur pull request, publication sur ghcr.io à chaque tag `v*`. Premier run réel : v0.1.0 a échoué (droits des fichiers montés sur un runner Linux), v0.1.1 a publié l'image.
- `test/grand-objet.sh`, `.github/workflows/s3-grand-objet.yml` : upload multipart en flux d'un objet de 5 Gio contre SeaweedFS, hors du test principal. Manuel ou sur changement du script ; `SIZE_MIB=1024 bash test/grand-objet.sh` pour un essai local. Ce n'est pas OVH.
- `.claude/skills/release/SKILL.md` : skill `/release`, crée et pousse le tag `vX.Y.Z` qui déclenche la publication. À garder cohérent avec `image.yml` (format du tag).
- `CONTRIBUTING.md`, `SECURITY.md` : à garder cohérents avec ce fichier (invariants, refus volontaires).

## Tester

- `bash test/run.sh` : environ 3 minutes, 14 cas, tout doit passer avant un commit qui touche `bin/pgdump-age` ou le `Dockerfile`. Postgres 18 + `adobe/s3mock` (épinglé), conteneur en lecture seule.
- `bash -n bin/pgdump-age test/run.sh` pour la syntaxe seule.
- Un test qui n'a jamais échoué ne prouve rien : pour un nouveau garde-fou, réintroduire le bug dans une copie du projet et vérifier que le test rouge l'attrape (c'est ainsi que les tests 7, 9, 12, 1 (contenu brut du bucket) et 14 ont été validés).

## Invariants à ne pas casser

- **Jamais de fichier de dump sur disque.** Le test tourne en `--read-only` avec `/tmp` de 8 Mo : une écriture disque le fait échouer. Pas de `mktemp` pour le flux.
- **`set -e` n'est pas fiable dans `backup_once` et `backup_db`** : appelées sous `||` en mode `schedule`, ce qui désactive `set -e` pour tout son corps. Chaque étape qui peut échouer se vérifie explicitement (`if ! cmd; then fail ...; return 1; fi`). Ne pas "simplifier" ces blocs.
- **Les trois statuts du pipeline** (`pg_dump`, `age`, `rclone`) sont lus via `PIPESTATUS` juste après le pipeline. Si `pg_dump` échoue en route, `age` et `rclone` terminent normalement un flux tronqué : seul ce contrôle empêche sa publication.
- **Un dump n'est valide que s'il a son `.ok`**, écrit en dernier et seulement si les trois statuts valent 0. `list`, `get` (nom explicite compris), `get latest` et la retention (`list_valid`) ignorent tout dump sans `.ok`. Le `.in_progress` est écrit avant le dump et rafraîchi toutes les `PROGRESS_EVERY` secondes (octets via `rclone rc core/stats`, serveur rc de `rclone rcat` : `127.0.0.1`, port tiré au hasard par run, jamais `--rc-no-auth`, qui ouvrirait les commandes rclone au reste du conteneur) ; il est supprimé après le `.ok`. Pas de `moveto` : aucune copie côté serveur. Le `.ok` part en premier à la suppression d'un dump, et le marqueur ne part qu'une fois le dump confirmé absent (`remove_dump`). Un listing en échec n'est jamais lu comme « absent » (`obj_state` renvoie 2). Au TERM, `progress_loop` finit son écriture en cours : le parent la `wait` avant d'écrire le `.ok`. La commande `adopt` écrit un `.ok` (`legacy=1`) aux dumps de v0.1.1, qui n'en ont pas.
- **La rétention ne tourne qu'après le dump réussi de la base concernée**, et jamais si le listing échoue ou si un dump plus récent existe. Un échec ne supprime rien.
- **Une seule base par conteneur (`PGDATABASE`)** : pas de liste, pas de boucle. Plusieurs bases = plusieurs conteneurs (un accessory par base).
- **`list_dumps` échoue si `rclone lsf` échoue** : ne jamais prendre une erreur de listing pour "aucun dump".
- **Le nettoyage des `.in_progress` est limité** à la base courante, au préfixe (`--max-depth 1`, filtre ancré) et à plus d'un jour : le bucket peut contenir d'autres objets. Il supprime le dump (sans `.ok`) avec son marqueur ; si le `.ok` existe (run tué entre le `.ok` et la suppression du marqueur), seul le marqueur part.
- **`tini -g`** dans l'`ENTRYPOINT` : sans lui, `docker stop` met 10 s puis tue le conteneur en plein upload.
- **Chiffrement `age` à clé publique** : le serveur ne détient jamais la clé privée. Ne pas passer à un chiffrement symétrique ni ajouter de clé privée à l'image.
- **Pas de secret en argument de commande** : tout passe par l'environnement (`PGPASSWORD`, `RCLONE_CONFIG_DEST_*`).

## Conventions

- Messages du script sans accents (`log`, `warn`, `fail`), préfixe `INFO`/`WARN`/`ERROR` : c'est ce que le monitoring recherchera. Le script, les exemples, les commentaires de test et ce fichier restent en français. README, CONTRIBUTING et SECURITY sont en anglais (documents communautaires) : ne pas les repasser en français, et garder cohérents les noms de variables et les extraits de logs qu'ils citent.
- Pas d'emojis ni de tirets cadratins dans le code, les logs et ce fichier. Le README en utilise (choix assumé pour un README communautaire) : ne pas les retirer.
- Commits : conventional commits, atomiques, message en français.
- Ne pas ajouter de dépendance (paquet Alpine, outil) pour quelques lignes de bash.
- Toute nouvelle variable d'environnement : la documenter dans le tableau du README et valider sa valeur dans `setup`.

## Non validé (ne pas affirmer le contraire)

- **Aucun test contre OVH réel** : seulement contre un S3 factice (s3mock) et SeaweedFS (objet de 5 Gio). Un point est à vérifier avant la prod (détaillé dans le README) : OVH doit lister les uploads multipart en cours pour que `rclone backend cleanup` fonctionne. Le `moveto` et la copie multipart côté serveur ne sont plus utilisés depuis les fichiers d'état.
- `S3_PROVIDER=OVHcloud` existe dans rclone 1.72 mais n'a jamais été essayé.
- Aucun dump de 121 Go n'a été fait ; le plafond de 312 Gio par objet (parts de 32 Mio, 10 000 parts) est un calcul confirmé par le message de rclone, pas une mesure.
- Pas de notification d'échec : seuls le code de sortie et les logs `ERROR`.
