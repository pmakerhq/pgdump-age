#!/usr/bin/env bash
# Test de bout en bout : Postgres 18 + serveur S3 factice (adobe/s3mock), image reelle, conteneur
# en lecture seule (aucun fichier de dump ne peut etre ecrit sur le disque du conteneur).
set -euo pipefail
cd "$(dirname "$0")/.."

P=pgbackuptest
COMPOSE=(docker compose -p "$P" -f test/compose.yml)
NET="${P}_default"
KEY=$(mktemp)
WRAP=$(mktemp)

cleanup() {
  docker rm -f pgb-sched pgb-term pgb-orphan >/dev/null 2>&1 || true
  "${COMPOSE[@]}" down -v >/dev/null 2>&1 || true
  rm -f "$KEY" "$WRAP"
}
trap cleanup EXIT

ok()  { echo "ok   - $*"; }
die() { echo "FAIL - $*" >&2; exit 1; }

docker build -q -t pg-backup:test . >/dev/null
"${COMPOSE[@]}" up -d --wait >/dev/null

docker run --rm --entrypoint age-keygen pg-backup:test 2>/dev/null >"$KEY"
PUB=$(sed -n 's/^# public key: //p' "$KEY")
[[ $PUB == age1* ]] || die "cle age non generee"

# Variables surchargeables par appel : PW, DB, KEEP, CHUNK ; XENV = options docker supplementaires.
XENV=()
ARGS=()
build_args() {
  ARGS=(--network "$NET"
    -e PGHOST=postgres -e PGUSER=backup -e PGPASSWORD="${PW:-backup-pw}" -e PGDATABASE="${DB:-app}"
    -e AGE_RECIPIENT="$PUB" -e S3_ENDPOINT=http://s3:9090 -e S3_REGION=us-east-1 -e S3_BUCKET=backups
    -e S3_ACCESS_KEY_ID=test -e S3_SECRET_ACCESS_KEY=test-secret -e KEEP="${KEEP:-3}"
    -e RCLONE_S3_CHUNK_SIZE="${CHUNK:-32M}")
  if [[ ${#XENV[@]} -gt 0 ]]; then ARGS+=("${XENV[@]}"); fi
}
# Conteneur en lecture seule : un fichier de dump ecrit sur disque ferait echouer le test.
run() { build_args; docker run --rm --read-only --tmpfs /tmp:size=8m "${ARGS[@]}" pg-backup:test "$@"; }
# rclone direct sur le meme bucket (remote T).
rc() {
  docker run -i --rm --network "$NET" --entrypoint rclone -e RCLONE_CONFIG=/dev/null \
    -e RCLONE_CONFIG_T_TYPE=s3 -e RCLONE_CONFIG_T_PROVIDER=Other -e RCLONE_CONFIG_T_ENDPOINT=http://s3:9090 \
    -e RCLONE_CONFIG_T_REGION=us-east-1 -e RCLONE_CONFIG_T_ACCESS_KEY_ID=test \
    -e RCLONE_CONFIG_T_SECRET_ACCESS_KEY=test-secret -e RCLONE_CONFIG_T_NO_CHECK_BUCKET=true \
    pg-backup:test "$@"
}
multipart_open() { rc backend list-multipart-uploads T:backups 2>/dev/null | grep -c '"Key"' || true; }
psql_pg() { "${COMPOSE[@]}" exec -T postgres psql -U postgres "$@"; }

# 1. Quatre runs : 3 dumps gardes, exactement les 3 plus recents.
names=()
for _ in 1 2 3 4; do
  run once >/dev/null
  names+=("$(run list | cut -d';' -f2 | sort | tail -n1)")
  sleep 1
done
expected=$(printf '%s\n' "${names[@]:1}" | sort)
actual=$(run list | cut -d';' -f2 | sort)
[[ $actual == "$expected" ]] || die "les 3 dumps gardes ne sont pas les 3 plus recents ($actual)"
ok "4 runs -> les 3 plus recents gardes, le plus ancien supprime"

# 2. Le dump se restaure hors de l'outil : age + pg_restore standards.
run get latest | docker run -i --rm --entrypoint age -v "$KEY:/key:ro" pg-backup:test -d -i /key \
  | docker run -i --rm --network "$NET" -e PGPASSWORD=postgres postgres:18 \
      pg_restore -h postgres -U postgres -d app_restore --no-owner
rows=$(psql_pg -d app_restore -Atc 'select count(*) from items')
[[ $rows -eq 20000 ]] || die "restauration : attendu 20000 lignes, obtenu $rows"
ok "restauration complete (20000 lignes)"

# 3. Echec de connexion avec KEEP=1 : si la retention tournait apres un echec, elle supprimerait 2 dumps.
before=$(run list | sort)
if PW=mauvais KEEP=1 run once >/dev/null 2>&1; then die "un mot de passe errone aurait du echouer"; fi
[[ $(run list | sort) == "$before" ]] || die "la liste des objets a change apres un echec"
ok "echec de connexion (KEEP=1) : rien supprime, rien publie"

# 4. Base inexistante : pg_dump echoue, age/rclone finissent normalement, le flux tronque n'est pas publie.
if DB=nexiste_pas run once >/dev/null 2>&1; then die "une base inexistante aurait du echouer"; fi
run list | grep -q 'nexiste_pas' && die "un objet a ete publie pour une base inexistante"
[[ $(run list | sort) == "$before" ]] || die "la liste des objets a change apres un pg_dump en echec"
ok "pg_dump en echec : aucun objet publie, rien supprime"

# 5. Nettoyage des .partial : seulement ceux de cette base, a la racine du prefixe, de plus d'un jour.
echo x | rc rcat T:backups/other/app-20200101T000000Z.dump.age.partial
echo x | rc rcat T:backups/unrelated.partial
echo x | rc rcat T:backups/app-20200101T000000Z.dump.age.partial
echo x | rc rcat T:backups/app-20991231T000000Z.dump.age.partial
for f in other/app-20200101T000000Z.dump.age.partial unrelated.partial app-20200101T000000Z.dump.age.partial; do
  rc touch -t 2020-01-01T00:00:00 "T:backups/$f"
done
run once >/dev/null
files=$(rc lsf -R T:backups)
grep -q '^other/app-20200101T000000Z.dump.age.partial$' <<<"$files" || die "un .partial d'un autre prefixe a ete supprime"
grep -q '^unrelated.partial$' <<<"$files"                          || die "un objet etranger a ete supprime"
grep -q '^app-20991231T000000Z.dump.age.partial$' <<<"$files"      || die "un .partial recent a ete supprime"
grep -q '^app-20200101T000000Z.dump.age.partial$' <<<"$files"      && die "le vieux .partial de la base n'a pas ete nettoye"
rc deletefile T:backups/other/app-20200101T000000Z.dump.age.partial
rc deletefile T:backups/unrelated.partial
rc deletefile T:backups/app-20991231T000000Z.dump.age.partial
ok "nettoyage des .partial limite a la base, au prefixe et a l'age"

# 6. Prefixe S3 : le dump atterrit sous le prefixe, pas a la racine.
XENV=(-e S3_PREFIX=/sub/dir/); run once >/dev/null; XENV=()
[[ $(rc lsf T:backups/sub/dir | grep -c '\.dump\.age$') -eq 1 ]] || die "dump absent sous le prefixe"
rc purge T:backups/sub >/dev/null
ok "S3_PREFIX respecte"

# 7. Mode schedule : un echec de moveto est un ERROR, jamais un "termine".
cat >"$WRAP" <<'EOF'
#!/bin/sh
if [ "$1" = moveto ]; then echo "echec simule de moveto" >&2; exit 1; fi
exec /usr/bin/rclone "$@"
EOF
chmod +x "$WRAP"
before=$(run list | grep -v partial | sort)
build_args
docker run -d --name pgb-sched --read-only --tmpfs /tmp:size=8m "${ARGS[@]}" -e RUN_ON_START=1 \
  -v "$WRAP:/usr/local/bin/rclone:ro" pg-backup:test schedule >/dev/null
for _ in $(seq 1 30); do
  docker logs pgb-sched 2>&1 | grep -q 'run de demarrage en echec' && break
  sleep 1
done
logs=$(docker logs pgb-sched 2>&1)
docker rm -f pgb-sched >/dev/null
grep -q 'ERROR.*publication.*impossible' <<<"$logs" || die "l'echec de moveto n'est pas journalise en ERROR: $logs"
grep -q 'termine :' <<<"$logs" && die "un moveto en echec est journalise comme une reussite"
[[ $(run list | grep -v partial | sort) == "$before" ]] || die "un dump a ete publie malgre l'echec de moveto"
for f in $(run list | grep partial | cut -d';' -f2); do rc deletefile "T:backups/$f"; done
ok "schedule : moveto en echec -> ERROR, rien publie, dumps existants intacts"

# Gros jeu de donnees pour les tests de flux (85 Mo apres compression).
psql_pg -d app -qc "CREATE TABLE big AS SELECT g AS id, md5(g::text) || md5((g*7)::text) AS a, md5((g*13)::text) AS b FROM generate_series(1, 1500000) g; GRANT SELECT ON big TO backup"

# 8. pg_dump tue en cours de flux : age/rclone finissent normalement, rien n'est publie.
before=$(run list | sort)
logf=$(mktemp)
XENV=(-e RCLONE_BWLIMIT=3M)
run once >"$logf" 2>&1 &
pid=$!
XENV=()
sleep 6
psql_pg -qAtc "select pg_terminate_backend(pid) from pg_stat_activity where usename='backup'" >/dev/null
if wait "$pid"; then die "un pg_dump tue en cours de route aurait du faire echouer le run"; fi
grep -q 'ERROR.*echec (pg_dump=' "$logf" || die "echec non journalise: $(cat "$logf")"
rm -f "$logf"
[[ $(run list | sort) == "$before" ]] || die "objet publie ou supprime apres un pg_dump tue en cours de flux"
ok "pg_dump tue en cours de flux : rien publie, partiel supprime"

# 9. SIGTERM pendant un upload : arret rapide (pas de SIGKILL de docker), code 0.
XENV=(-e RCLONE_BWLIMIT=3M -e RUN_ON_START=1); build_args; XENV=()
docker run -d --name pgb-term --read-only --tmpfs /tmp:size=8m "${ARGS[@]}" pg-backup:test schedule >/dev/null
sleep 6
start=$SECONDS
docker stop pgb-term >/dev/null
elapsed=$((SECONDS - start))
code=$(docker inspect -f '{{.State.ExitCode}}' pgb-term)
docker rm -f pgb-term >/dev/null
[[ $elapsed -lt 8 ]] || die "docker stop a mis ${elapsed}s : SIGTERM non propage (SIGKILL apres 10 s)"
[[ $code -eq 0 ]]    || die "code de sortie ${code} apres SIGTERM"
ok "SIGTERM pendant un upload : arret en ${elapsed}s, code 0"

# 10. Upload multipart orphelin (conteneur tue) : nettoye au run suivant.
docker run -d --name pgb-orphan --network "$NET" --entrypoint sh -e RCLONE_CONFIG=/dev/null \
  -e RCLONE_CONFIG_T_TYPE=s3 -e RCLONE_CONFIG_T_PROVIDER=Other -e RCLONE_CONFIG_T_ENDPOINT=http://s3:9090 \
  -e RCLONE_CONFIG_T_REGION=us-east-1 -e RCLONE_CONFIG_T_ACCESS_KEY_ID=test \
  -e RCLONE_CONFIG_T_SECRET_ACCESS_KEY=test-secret -e RCLONE_CONFIG_T_NO_CHECK_BUCKET=true \
  -e RCLONE_S3_CHUNK_SIZE=5M pg-backup:test \
  -c 'head -c 419430400 /dev/urandom | rclone rcat --bwlimit 4M T:backups/orphan.partial' >/dev/null
sleep 8
docker kill pgb-orphan >/dev/null; docker rm -f pgb-orphan >/dev/null
[[ $(multipart_open) -ge 1 ]] || die "l'upload orphelin n'a pas ete cree (test invalide)"
XENV=(-e MULTIPART_MAX_AGE=1s); run once >/dev/null; XENV=()
[[ $(multipart_open) -eq 0 ]] || die "l'upload multipart orphelin n'a pas ete nettoye"
ok "upload multipart orphelin nettoye au run suivant"

# 11. Gros dump : multipart en flux (parts de 5 Mio) puis copie multipart cote serveur (moveto).
XENV=(-e RCLONE_S3_COPY_CUTOFF=5M)
CHUNK=5M run once >/dev/null 2>&1 || die "echec du gros dump"
XENV=()
big=$(run list | grep '\.dump\.age$' | sort -t';' -k2 | tail -n1 | cut -d';' -f1)
[[ $big -gt 20000000 ]] || die "gros dump trop petit pour exercer le multipart ($big octets)"
psql_pg -qc "CREATE DATABASE app_restore_big"
run get latest | docker run -i --rm --entrypoint age -v "$KEY:/key:ro" pg-backup:test -d -i /key \
  | docker run -i --rm --network "$NET" -e PGPASSWORD=postgres postgres:18 \
      pg_restore -h postgres -U postgres -d app_restore_big --no-owner \
  || die "restauration du gros dump en echec"
rows=$(psql_pg -d app_restore_big -Atc 'select count(*) from big')
[[ $rows -eq 1500000 ]] || die "gros dump : attendu 1500000 lignes, obtenu $rows"
ok "gros dump (${big} octets) en multipart + copie multipart, restaure (1500000 lignes)"

echo "tous les tests passent"
