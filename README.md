# pg-backup

Sauvegarde quotidienne d'**une base PostgreSQL en un seul fichier compressé et chiffré** sur S3, sans écrire de fichier local :

```
pg_dump --format=custom --compress=zstd:5  |  age --recipient <cle publique>  |  rclone rcat  ->  <base>-AAAAMMJJTHHMMSSZ.dump.age
```

Une image Alpine (`pg_dump` 18, `age`, `rclone`, `bash`), un script (`bin/pg-backup`), aucune dépendance applicative.

## Garanties

- **Un objet par run**, pas de dépôt ni de manifest : `oddscore_staging-20261007T033000Z.dump.age`.
- **Rien sur disque** : le conteneur tourne en lecture seule dans les tests.
- **Publication atomique** : le flux est écrit en `<nom>.partial`, puis renommé seulement si `pg_dump`, `age` et `rclone` ont tous réussi et que l'objet n'est pas vide. Un dump tronqué n'est jamais publié.
- **Rétention par nombre** (`KEEP`, défaut 3), appliquée **uniquement après un run réussi** : un échec ne supprime rien.
- Chiffrement `age` à clé publique : le serveur ne peut pas déchiffrer ses propres sauvegardes.

## Configuration (variables d'environnement)

| Variable | Rôle |
|---|---|
| `PGHOST`, `PGUSER`, `PGPASSWORD`, `PGDATABASE` | Connexion. Rôle en lecture seule (`GRANT pg_read_all_data`), connexion directe (pas de PgBouncer). `PGPORT` optionnel. |
| `AGE_RECIPIENT` | Clé publique age (`age1...`). Générer avec `age-keygen`, garder la clé privée hors serveur. |
| `S3_ENDPOINT`, `S3_BUCKET`, `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY` | Destination. `S3_REGION` et `S3_PREFIX` optionnels. |
| `KEEP` | Dumps conservés (défaut `3`). |
| `BACKUP_AT` | Heure du run quotidien, `HH:MM` UTC (défaut `03:30`). |
| `RUN_ON_START` | `1` pour lancer un backup au démarrage du conteneur. |
| `PG_COMPRESS` | Compression de `pg_dump` (défaut `zstd:5`). |
| `RCLONE_S3_CHUNK_SIZE`, `RCLONE_S3_UPLOAD_CONCURRENCY` | Parts de l'upload (défaut `32M` x 2, plafond d'environ 312 Gio par objet). |

Le nom de base ne peut contenir que `[A-Za-z0-9_-]`. Une base par conteneur.

## Commandes

```sh
pg-backup schedule   # défaut : un run par jour à BACKUP_AT
pg-backup once       # un run immédiat
pg-backup list       # taille;nom des objets
pg-backup get latest > dump.age
```

## Restaurer, sans cet outil

```sh
age -d -i cle-privee.txt dump.age | pg_restore -d <base> --no-owner
```

C'est un `pg_dump --format=custom` standard : `pg_restore` 16 ou plus pour le zstd.

## Tests

`bash test/run.sh` (Docker requis) : Postgres 18 + serveur S3 factice, image réelle, conteneur en lecture seule. Vérifie : 4 runs donnent 3 dumps, restauration complète via `age` + `pg_restore`, échec de connexion sans effet de bord, `pg_dump` en échec sans objet publié, gros dump en multipart.

Le serveur S3 des tests n'est pas OVH : **le comportement réel contre OVH Object Storage n'est pas testé**.

## Limites connues

- Pas de notification d'échec : le code de sortie et les logs `ERROR` sont à surveiller (Loki, alerte).
- Un run interrompu laisse un `.partial`, nettoyé au run suivant s'il a plus d'un jour.
- Pas de planning intelligent : si le conteneur redémarre après `BACKUP_AT`, le run saute à la veille suivante (sauf `RUN_ON_START=1`).
