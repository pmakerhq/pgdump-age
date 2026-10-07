#!/usr/bin/env bash
# Test de bout en bout : Postgres 18 + serveur S3 factice (adobe/s3mock), image reelle, conteneur en lecture seule
# (aucun fichier de dump ne peut etre ecrit sur le disque du conteneur).
set -euo pipefail
cd "$(dirname "$0")/.."

P=pgbackuptest
COMPOSE=(docker compose -p "$P" -f test/compose.yml)
NET="${P}_default"
KEY=$(mktemp)

cleanup() { "${COMPOSE[@]}" down -v >/dev/null 2>&1 || true; rm -f "$KEY"; }
trap cleanup EXIT

ok()  { echo "ok   - $*"; }
die() { echo "FAIL - $*" >&2; exit 1; }

docker build -q -t pg-backup:test . >/dev/null
"${COMPOSE[@]}" up -d --wait >/dev/null

docker run --rm --entrypoint age-keygen pg-backup:test 2>/dev/null >"$KEY"
PUB=$(sed -n 's/^# public key: //p' "$KEY")
[[ $PUB == age1* ]] || die "cle age non generee"

# $1.. = args de pg-backup ; variables PW, DB et CHUNK surchargeables
run() {
  docker run --rm --network "$NET" --read-only --tmpfs /tmp:size=8m \
    -e PGHOST=postgres -e PGUSER=backup -e PGPASSWORD="${PW:-backup-pw}" -e PGDATABASE="${DB:-app}" \
    -e AGE_RECIPIENT="$PUB" -e S3_ENDPOINT=http://s3:9090 -e S3_BUCKET=backups \
    -e S3_ACCESS_KEY_ID=test -e S3_SECRET_ACCESS_KEY=test-secret -e KEEP=3 \
    -e RCLONE_S3_CHUNK_SIZE="${CHUNK:-32M}" \
    pg-backup:test "$@"
}

# Le bucket `backups` est cree par s3mock au demarrage.

# 1. Quatre runs : 3 dumps gardes, les plus recents.
for _ in 1 2 3 4; do run once >/dev/null; sleep 1; done
count=$(run list | grep -c '\.dump\.age$' || true)
[[ $count -eq 3 ]] || die "attendu 3 dumps apres 4 runs, obtenu $count"
run list | grep -q 'partial' && die "objet .partial restant"
ok "4 runs -> 3 dumps, aucun partiel"

# 2. Le dump se restaure hors de l'outil : age + pg_restore standards.
run get latest | docker run -i --rm --entrypoint age -v "$KEY:/key:ro" pg-backup:test -d -i /key \
  | docker run -i --rm --network "$NET" -e PGPASSWORD=postgres postgres:18 \
      pg_restore -h postgres -U postgres -d app_restore --no-owner
rows=$("${COMPOSE[@]}" exec -T postgres psql -U postgres -d app_restore -Atc 'select count(*) from items')
[[ $rows -eq 20000 ]] || die "restauration : attendu 20000 lignes, obtenu $rows"
ok "restauration complete (20000 lignes)"

# 3. Echec de connexion : code non nul, dumps existants intacts, pas de partiel.
before=$(run list | sort)
if PW=mauvais run once >/dev/null 2>&1; then die "un mot de passe errone aurait du echouer"; fi
[[ $(run list | sort) == "$before" ]] || die "la liste des objets a change apres un echec"
ok "echec de connexion : rien supprime, rien publie"

# 4. Base inexistante : pg_dump echoue, age/rclone finissent normalement, le flux tronque n'est pas publie.
if DB=nexiste_pas run once >/dev/null 2>&1; then die "une base inexistante aurait du echouer"; fi
run list | grep -q 'nexiste_pas' && die "un objet a ete publie pour une base inexistante"
ok "pg_dump en echec : aucun objet publie"

# 5. Gros dump : upload multipart en flux (parts de 5 Mio), restauration lisible.
"${COMPOSE[@]}" exec -T postgres psql -U postgres -d app -qc \
  "CREATE TABLE big AS SELECT g AS id, md5(g::text) || md5((g*7)::text) AS a, md5((g*13)::text) AS b FROM generate_series(1, 1500000) g; GRANT SELECT ON big TO backup"
CHUNK=5M run once >/dev/null 2>&1 || die "echec du gros dump"
big=$(run list | grep '\.dump\.age$' | sort -t';' -k2 | tail -n1 | cut -d';' -f1)
[[ $big -gt 20000000 ]] || die "gros dump trop petit pour exercer le multipart ($big octets)"
"${COMPOSE[@]}" exec -T postgres psql -U postgres -qc "CREATE DATABASE app_restore_big"
run get latest | docker run -i --rm --entrypoint age -v "$KEY:/key:ro" pg-backup:test -d -i /key \
  | docker run -i --rm --network "$NET" -e PGPASSWORD=postgres postgres:18 \
      pg_restore -h postgres -U postgres -d app_restore_big --no-owner \
  || die "restauration du gros dump en echec"
rows=$("${COMPOSE[@]}" exec -T postgres psql -U postgres -d app_restore_big -Atc 'select count(*) from big')
[[ $rows -eq 1500000 ]] || die "gros dump : attendu 1500000 lignes, obtenu $rows"
ok "gros dump (${big} octets) en multipart, restaure (1500000 lignes)"

echo "tous les tests passent"
