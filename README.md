# pg-backup

Sauvegarde quotidienne d'**une base PostgreSQL en un seul fichier compressé et chiffré** sur S3, sans écrire de fichier local :

```
pg_dump --format=custom --compress=zstd:5  |  age --recipient <cle publique>  |  rclone rcat  ->  <base>-AAAAMMJJTHHMMSSZ.dump.age
```

Une image Alpine (`pg_dump` 18, `age`, `rclone`, `bash`, `tini`), un script (`bin/pg-backup`), aucune dépendance applicative.

## Garanties

- **Un objet par run**, pas de dépôt ni de manifest : `oddscore_staging-20261007T033000Z.dump.age`.
- **Rien sur disque** : le conteneur tourne en lecture seule dans les tests.
- **Publication en deux temps** : le flux est écrit en `<nom>.partial`, puis renommé seulement si `pg_dump`, `age` et `rclone` ont tous réussi et que l'objet n'est pas vide. Un dump tronqué n'est jamais publié.
- **Rétention par nombre** (`KEEP`, défaut 3), appliquée **uniquement après un run réussi** et seulement si le nouveau dump est le plus récent du listing (horloge en retard : rien n'est supprimé). Un échec ne supprime rien.
- Chiffrement `age` à clé publique : le serveur ne peut pas déchiffrer ses propres sauvegardes.
- Les erreurs sont toujours journalisées en `ERROR`, y compris en mode `schedule` (où `set -e` ne s'applique pas : chaque étape est vérifiée explicitement).
- `docker stop` arrête proprement un upload en cours (`tini -g` envoie SIGTERM à tout le groupe de processus).

## Configuration (variables d'environnement)

| Variable | Rôle |
|---|---|
| `PGHOST`, `PGUSER`, `PGPASSWORD`, `PGDATABASE` | Connexion. Rôle en lecture seule (`GRANT pg_read_all_data`), connexion directe (pas de PgBouncer). `PGPORT` optionnel. |
| `AGE_RECIPIENT` | Clé publique age (`age1...`). Générer avec `age-keygen`, garder la clé privée hors serveur. |
| `S3_ENDPOINT`, `S3_REGION`, `S3_BUCKET`, `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY` | Destination. La région est obligatoire : OVH vérifie la région dans la signature des requêtes (par exemple `sbg`). `S3_PREFIX` optionnel. |
| `S3_PROVIDER` | Provider rclone (défaut `Other`). `OVHcloud` existe dans rclone 1.72 : à essayer pour OVH, **non testé**. |
| `KEEP` | Dumps conservés (défaut `3`). |
| `BACKUP_AT` | Heure du run quotidien, `HH:MM` UTC (défaut `03:30`). |
| `RUN_ON_START` | `1` pour lancer un backup au démarrage du conteneur. **À éviter avec `restart: unless-stopped`** : chaque redémarrage prend un dump complet, et quelques redémarrages de suite repoussent les sauvegardes des jours précédents hors des `KEEP` conservés. Pour un premier run manuel, utiliser `pg-backup once`. |
| `PG_COMPRESS` | Compression de `pg_dump` (défaut `zstd:5`). |
| `MULTIPART_MAX_AGE` | Âge à partir duquel un upload multipart abandonné est nettoyé (défaut `24h`). |
| `RCLONE_S3_CHUNK_SIZE`, `RCLONE_S3_UPLOAD_CONCURRENCY` | Parts de l'upload (défaut `32M` x 2, plafond d'environ 312 Gio par objet). |

Le nom de base ne peut contenir que `[A-Za-z0-9_-]`. Une base par conteneur. Sans `S3_PREFIX`, le nettoyage des uploads abandonnés couvre tout le bucket : utiliser un bucket dédié, ou un préfixe.

## Commandes

```sh
pg-backup schedule   # défaut : un run par jour à BACKUP_AT
pg-backup once       # un run immédiat
pg-backup list       # taille;nom des objets (y compris les .partial)
pg-backup get latest > dump.age
```

## Restaurer, sans cet outil

```sh
age -d -i cle-privee.txt dump.age | pg_restore -d <base> --no-owner
```

- C'est un `pg_dump --format=custom` standard, d'archive 1.16 : **`pg_restore` 17 ou plus** (16 refuse de le lire), de préférence 18.
- Ce pipe est mono-processus : pour une grosse base, déchiffrer d'abord dans un fichier (il faut alors l'espace disque sur la machine de restauration) puis restaurer en parallèle :

```sh
age -d -i cle-privee.txt dump.age > base.dump
pg_restore -j 4 -d <base> --no-owner base.dump
```

## Avant la production : valider contre OVH

Les tests tournent contre un serveur S3 factice. Deux comportements doivent être vérifiés contre le vrai OVH avant de compter sur l'outil pour une grosse base :

1. **Le renommage final (`rclone moveto`) est une copie côté serveur** : une seconde écriture complète de l'objet. Au-delà de 4,6 Gio rclone utilise une copie multipart (`UploadPartCopy`). Si OVH ne la supporte pas ou la rend très lente, un dump de dizaines de Go échouerait à cette étape après des heures de dump, en laissant le `.partial`. Tester un renommage réel de plus de 5 Gio :
   ```sh
   head -c 6G /dev/urandom | rclone rcat ovh:bucket/test.partial
   time rclone moveto ovh:bucket/test.partial ovh:bucket/test.bin
   ```
2. **Le nettoyage des uploads multipart abandonnés** (`rclone backend cleanup`) suppose qu'OVH liste les uploads en cours. Vérifier avec `rclone backend list-multipart-uploads ovh:bucket`.

## Tests

`bash test/run.sh` (Docker requis) : Postgres 18 + serveur S3 factice, image réelle, conteneur en lecture seule. Vérifie :

- 4 runs donnent exactement les 3 plus récents dumps ;
- restauration complète via `age` + `pg_restore` ;
- échec de connexion avec `KEEP=1` : rien supprimé, rien publié ;
- `pg_dump` en échec, ou tué en cours de flux : rien publié ;
- nettoyage des `.partial` limité à la base, au préfixe et à l'âge ;
- `S3_PREFIX` ;
- mode `schedule` avec un `moveto` en échec : `ERROR`, jamais `termine`, rien publié ;
- `docker stop` pendant un upload : arrêt rapide, code 0 ;
- upload multipart orphelin nettoyé au run suivant ;
- gros dump de 86 Mo en multipart, copie multipart au renommage, restauration de 1,5 million de lignes.

Le serveur S3 des tests n'est pas OVH : **le comportement réel contre OVH Object Storage n'est pas testé** (voir la section précédente).

## Limites connues

- Pas de notification d'échec : le code de sortie et les logs `ERROR` sont à surveiller (Loki, alerte). En mode `schedule`, le conteneur reste vivant après un échec et réessaie le lendemain.
- Un run tué en plein upload laisse des parts multipart invisibles, nettoyées au run suivant après `MULTIPART_MAX_AGE`. Un `.partial` n'existe que si le processus est tué entre la fin de l'upload et le renommage ; il est supprimé au run suivant au bout d'un jour.
- Si le conteneur redémarre après `BACKUP_AT`, le run est sauté jusqu'au lendemain (sauf `RUN_ON_START=1`, voir plus haut).
