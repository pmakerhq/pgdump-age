# 🔐 pgdump-age

![License: MIT](https://img.shields.io/badge/license-MIT-blue)
![CI](https://github.com/pmakerhq/pgdump-age/actions/workflows/image.yml/badge.svg)

**A compressed, encrypted `pg_dump` of one or several PostgreSQL 18 databases, one file each on S3. Nothing written to disk.**

```
pg_dump --format=custom --compress=zstd:5  |  age --recipient <public key>  |  rclone rcat  ->  mydb-20261007T033000Z.dump.age
```

- One object per database and per backup, one dump per day at `BACKUP_AT` (UTC). Databases are dumped one after the other.
- Encrypted with [age](https://github.com/FiloSottile/age): the server holds the public key only, you keep the private one.
- State files next to each dump: `<dump>.in_progress` while it runs (bytes sent so far, refreshed every `PROGRESS_EVERY` seconds), `<dump>.ok` once `pg_dump`, `age` and `rclone` all succeeded (size, duration). A dump without `.ok` is never listed, restored by `get latest` or counted by the retention. No rename, no server-side copy.
- Keeps the last `KEEP` dumps of each database, prunes a database only after its own successful dump. A failing database does not stop the others (the run exits non-zero).
- Restorable without this tool: `age -d` then `pg_restore`.

## 🚀 Quick start

**1. Generate the age key pair** (keep the private key in your password manager, never on the server):

```sh
age-keygen -o private-key.txt     # prints the public key age1...
```

**2. Create a read-only role** (as superuser, on the database to back up):

```sql
CREATE ROLE backup LOGIN PASSWORD 'CHANGE-ME';   -- no URL special characters (@ : / % # ?)
GRANT pg_read_all_data TO backup;
```

Tables with row-level security need `ALTER ROLE backup BYPASSRLS`. `pg_hba.conf` must allow the role from the container's host.

**3. Run a dump:**

```sh
docker run --rm --read-only --tmpfs /tmp:size=8m \
  -e PGHOST=db.example.com -e PGUSER=backup -e PGPASSWORD='...' -e PGDATABASES=mydb \
  -e AGE_RECIPIENT=age1... \
  -e S3_ENDPOINT=https://s3.example.com -e S3_REGION=us-east-1 -e S3_BUCKET=my-backups \
  -e S3_ACCESS_KEY_ID='...' -e S3_SECRET_ACCESS_KEY='...' \
  ghcr.io/pmakerhq/pgdump-age:v0.1.1 once
```

Replace `once` with `list` to check. With no command the container runs `schedule`.

## 🚢 Kamal

In `config/deploy.yml`:

```yaml
accessories:
  pg_backup:
    image: ghcr.io/pmakerhq/pgdump-age:v0.1.1   # pin a version, never latest
    host: 10.0.0.10   # must reach Postgres directly, not through PgBouncer
    env:
      clear:
        PGHOST: 10.0.0.10
        PGPORT: "5432"
        PGUSER: backup
        PGDATABASES: myapp_production   # comma-separated: myapp_production,myapp_analytics
        AGE_RECIPIENT: age1...        # public key, not a secret
        S3_ENDPOINT: https://s3.sbg.io.cloud.ovh.net
        S3_REGION: sbg
        S3_BUCKET: myapp-backups
        KEEP: "3"
        BACKUP_AT: "03:30"            # HH:MM UTC
      secret:   # name in the container : name in .kamal/secrets
        - PGPASSWORD:BACKUP_DB_PASSWORD
        - S3_ACCESS_KEY_ID:BACKUP_S3_ACCESS_KEY_ID
        - S3_SECRET_ACCESS_KEY:BACKUP_S3_SECRET_ACCESS_KEY
    options:
      read-only: true
      tmpfs: /tmp:size=8m
      cpus: "1"
```

In `.kamal/secrets` (Bitwarden is only an example, any `kamal secrets` adapter works):

```sh
SECRETS=$(kamal secrets fetch --adapter bitwarden --account you@example.com BACKUP_DB_PASSWORD BACKUP_S3_ACCESS_KEY_ID BACKUP_S3_SECRET_ACCESS_KEY)
BACKUP_DB_PASSWORD=$(kamal secrets extract BACKUP_DB_PASSWORD ${SECRETS})
BACKUP_S3_ACCESS_KEY_ID=$(kamal secrets extract BACKUP_S3_ACCESS_KEY_ID ${SECRETS})
BACKUP_S3_SECRET_ACCESS_KEY=$(kamal secrets extract BACKUP_S3_SECRET_ACCESS_KEY ${SECRETS})
```

> ⚠️ Create the three secrets **before** adding these lines: a missing item makes every Kamal command fail, `kamal deploy` included.

```sh
bin/kamal accessory boot pg_backup
bin/kamal accessory exec pg_backup --reuse "pgdump-age once"   # first run, without waiting for BACKUP_AT
bin/kamal accessory exec pg_backup --reuse "pgdump-age list"
```

The `docker run` command rendered by Kamal 2.12 from this block was checked, but it has **not** been deployed to a real server.

## ⚙️ Configuration

| Variable | Purpose |
|---|---|
| `PGHOST`, `PGUSER`, `PGPASSWORD` | Connection (`PGPORT` optional). Direct connection, no PgBouncer. The role must read every database |
| `PGDATABASES` | Databases to dump, comma-separated (`app,analytics`). Names: `[A-Za-z0-9_-]` only, no duplicates |
| `AGE_RECIPIENT` | age public key (`age1...`) |
| `S3_ENDPOINT`, `S3_REGION`, `S3_BUCKET`, `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY` | Destination. The region is required (OVH checks it in the signature). `S3_PREFIX` optional |
| `KEEP` | Dumps to keep per database (default `3`) |
| `BACKUP_AT` | Daily run time, `HH:MM` UTC (default `03:30`) |
| `RUN_ON_START` | `1` dumps at container start. **Avoid it with a restart policy**: each restart takes a dump and pushes older ones out of `KEEP` |
| `PG_COMPRESS` | `pg_dump` compression (default `zstd:5`) |
| `PROGRESS_EVERY` | Seconds between two refreshes of the `.in_progress` file (default `30`) |
| `MULTIPART_MAX_AGE` | Age after which an abandoned upload is cleaned up (default `24h`) |
| `S3_PROVIDER` | rclone provider (default `Other`). `OVHcloud` is **untested** |
| `RCLONE_S3_CHUNK_SIZE`, `RCLONE_S3_UPLOAD_CONCURRENCY` | Upload parts (default `32M` x 2, about 312 GiB maximum per object) |

Without `S3_PREFIX`, the cleanup of abandoned uploads covers the whole bucket: use a dedicated bucket or a prefix.

Commands: `schedule` (default), `once`, `list` (valid dumps only, `size;name`), `adopt` (see [Upgrading from v0.1.1](#upgrading-from-v011)), `get latest [database] > dump.age` (the database is required when `PGDATABASES` lists several). Logs are prefixed `INFO`, `WARN` or `ERROR` (messages in French, no accents): alert on `ERROR`.

## 🔓 Restoring

```sh
age -d -i private-key.txt dump.age | pg_restore -d mydb --no-owner
```

You need **`pg_restore` 17 or newer** (16 refuses the archive). For a large database, decrypt to a file first (needs disk space), then `pg_restore -j 4 -d mydb --no-owner db.dump`.

## ⬆️ Upgrading from v0.1.1

v0.1.1 dumps have no `.ok` file, so `list`, `get` and the retention ignore them (and never delete them). Stop the old container, start the new image, then run once:

```sh
docker run --rm ... ghcr.io/pmakerhq/pgdump-age:<new version> adopt     # same environment as for a dump
```

`adopt` writes a `.ok` (with `legacy=1`) for every dump that has neither `.ok` nor `.in_progress`, and deletes the `.partial` files v0.1.1 may have left for the configured databases. With Kamal: `kamal accessory exec pg_backup --reuse "pgdump-age adopt"`.

## ⚠️ Known limits

Tested against fake S3 servers, **not against OVH Object Storage**: `bash test/run.sh` (Docker required, about 2 minutes) and, in a separate CI job, a 5 GiB streamed multipart upload on SeaweedFS (`test/grand-objet.sh`). Check this before relying on it for a large database:

1. **Cleanup of abandoned uploads** needs the provider to list in-progress uploads: `rclone backend list-multipart-uploads ovh:bucket`.

Nothing is renamed or copied server-side: a dump is valid when its `.ok` file exists. A run killed mid-upload leaves its `.in_progress` file and no `.ok`; the first run that finds the marker unrefreshed for more than a day deletes it (and the dump, if any), so in practice the run after next. `get <name>` takes an exact dump name (no pattern) and refuses a dump without `.ok`. The progress and `.ok` files are plain `key=value` text.

Also: no failure notification (watch `ERROR` logs and the exit code) and no real 121 GB dump measured.

## 📦 Releases

A `vX.Y.Z` tag runs the tests, then publishes `ghcr.io/pmakerhq/pgdump-age:vX.Y.Z` ([workflow](.github/workflows/image.yml)). Maintainers: run `/release` in Claude Code ([skill](.claude/skills/release/SKILL.md)), or `git tag -a vX.Y.Z -m vX.Y.Z && git push origin vX.Y.Z` from an up-to-date `main`.

[Contributing](CONTRIBUTING.md) · [Security](SECURITY.md) · [MIT](LICENSE)
