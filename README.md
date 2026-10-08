# 🔐 pgdump-age

![License: MIT](https://img.shields.io/badge/license-MIT-blue)
![CI](https://github.com/pmakerhq/pgdump-age/actions/workflows/image.yml/badge.svg)

**A compressed, encrypted `pg_dump` of one PostgreSQL 18 database, as a single file on S3. Nothing written to disk.**

```
pg_dump --format=custom --compress=zstd:5  |  age --recipient <public key>  |  rclone rcat  ->  mydb-20261007T033000Z.dump.age
```

- One object per backup, one container per database, one dump per day at `BACKUP_AT` (UTC).
- Encrypted with [age](https://github.com/FiloSottile/age): the server holds the public key only, you keep the private one.
- Uploaded as `.partial`, renamed only if `pg_dump`, `age` and `rclone` all succeeded: a truncated dump is never published.
- Keeps the last `KEEP` dumps, prunes only after a successful run.
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
  -e PGHOST=db.example.com -e PGUSER=backup -e PGPASSWORD='...' -e PGDATABASE=mydb \
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
        PGDATABASE: myapp_production
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
| `PGHOST`, `PGUSER`, `PGPASSWORD`, `PGDATABASE` | Connection (`PGPORT` optional). Direct connection, no PgBouncer. Database name: `[A-Za-z0-9_-]` only |
| `AGE_RECIPIENT` | age public key (`age1...`) |
| `S3_ENDPOINT`, `S3_REGION`, `S3_BUCKET`, `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY` | Destination. The region is required (OVH checks it in the signature). `S3_PREFIX` optional |
| `KEEP` | Dumps to keep (default `3`) |
| `BACKUP_AT` | Daily run time, `HH:MM` UTC (default `03:30`) |
| `RUN_ON_START` | `1` dumps at container start. **Avoid it with a restart policy**: each restart takes a dump and pushes older ones out of `KEEP` |
| `PG_COMPRESS` | `pg_dump` compression (default `zstd:5`) |
| `MULTIPART_MAX_AGE` | Age after which an abandoned upload is cleaned up (default `24h`) |
| `S3_PROVIDER` | rclone provider (default `Other`). `OVHcloud` is **untested** |
| `RCLONE_S3_CHUNK_SIZE`, `RCLONE_S3_UPLOAD_CONCURRENCY` | Upload parts (default `32M` x 2, about 312 GiB maximum per object) |

Without `S3_PREFIX`, the cleanup of abandoned uploads covers the whole bucket: use a dedicated bucket or a prefix.

Commands: `schedule` (default), `once`, `list`, `get latest > dump.age`. Logs are prefixed `INFO`, `WARN` or `ERROR` (messages in French, no accents): alert on `ERROR`.

## 🔓 Restoring

```sh
age -d -i private-key.txt dump.age | pg_restore -d mydb --no-owner
```

You need **`pg_restore` 17 or newer** (16 refuses the archive). For a large database, decrypt to a file first (needs disk space), then `pg_restore -j 4 -d mydb --no-owner db.dump`.

## ⚠️ Known limits

Tested against fake S3 servers, **not against OVH Object Storage**: `bash test/run.sh` (Docker required, about 2 minutes) and, in a separate CI job, a 5 GiB object on SeaweedFS (`test/grand-objet.sh`, above rclone's multipart copy threshold). Check these before relying on it for a large database:

1. **The final rename (`rclone moveto`) is a server-side copy**, a second full write of the object (multipart above 4.6 GiB). If OVH does not support it or is very slow, a big dump fails at this step after hours, leaving the `.partial`. Test it:
   ```sh
   head -c 6G /dev/urandom | rclone rcat ovh:bucket/test.partial
   time rclone moveto ovh:bucket/test.partial ovh:bucket/test.bin
   ```
2. **Cleanup of abandoned uploads** needs the provider to list in-progress uploads: `rclone backend list-multipart-uploads ovh:bucket`.

Also: no failure notification (watch `ERROR` logs and the exit code) and no real 121 GB dump measured.

## 📦 Releases

A `vX.Y.Z` tag runs the tests, then publishes `ghcr.io/pmakerhq/pgdump-age:vX.Y.Z` ([workflow](.github/workflows/image.yml)). Maintainers: run `/release` in Claude Code ([skill](.claude/skills/release/SKILL.md)), or `git tag -a vX.Y.Z -m vX.Y.Z && git push origin vX.Y.Z` from an up-to-date `main`.

[Contributing](CONTRIBUTING.md) · [Security](SECURITY.md) · [MIT](LICENSE)
