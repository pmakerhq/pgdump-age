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

docker build -q -t pgdump-age:test . >/dev/null
"${COMPOSE[@]}" up -d --wait >/dev/null

docker run --rm --entrypoint age-keygen pgdump-age:test 2>/dev/null >"$KEY"
# mktemp cree en 0600 : le conteneur (uid 10001) ne lit pas la cle sur un runner Linux (uid different).
chmod 644 "$KEY"
PUB=$(sed -n 's/^# public key: //p' "$KEY")
[[ $PUB == age1* ]] || die "cle age non generee"

# Variables surchargeables par appel : PW, DB (liste PGDATABASES), KEEP, CHUNK ; XENV = options docker supplementaires.
XENV=()
ARGS=()
build_args() {
  ARGS=(--network "$NET"
    -e PGHOST=postgres -e PGUSER=backup -e PGPASSWORD="${PW:-backup-pw}" -e PGDATABASES="${DB:-app}"
    -e AGE_RECIPIENT="$PUB" -e S3_ENDPOINT=http://s3:9090 -e S3_REGION=us-east-1 -e S3_BUCKET=backups
    -e S3_ACCESS_KEY_ID=test -e S3_SECRET_ACCESS_KEY=test-secret -e KEEP="${KEEP:-3}"
    -e RCLONE_S3_CHUNK_SIZE="${CHUNK:-32M}")
  if [[ ${#XENV[@]} -gt 0 ]]; then ARGS+=("${XENV[@]}"); fi
}
# Conteneur en lecture seule : un fichier de dump ecrit sur disque ferait echouer le test.
run() { build_args; docker run --rm --read-only --tmpfs /tmp:size=8m "${ARGS[@]}" pgdump-age:test "$@"; }
# rclone direct sur le meme bucket (remote T).
rc() {
  docker run -i --rm --network "$NET" --entrypoint rclone -e RCLONE_CONFIG=/dev/null \
    -e RCLONE_CONFIG_T_TYPE=s3 -e RCLONE_CONFIG_T_PROVIDER=Other -e RCLONE_CONFIG_T_ENDPOINT=http://s3:9090 \
    -e RCLONE_CONFIG_T_REGION=us-east-1 -e RCLONE_CONFIG_T_ACCESS_KEY_ID=test \
    -e RCLONE_CONFIG_T_SECRET_ACCESS_KEY=test-secret -e RCLONE_CONFIG_T_NO_CHECK_BUCKET=true \
    pgdump-age:test "$@"
}
# Contenu brut du bucket (dumps, .ok, .in_progress), pour verifier qu'un echec ne laisse rien.
raw() { rc lsf T:backups | sort; }
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
# Le bucket lui-meme (pas seulement list) : pas de dump ni de .ok orphelin, aucun marqueur.
raw_now=$(raw)
[[ $(grep -c '\.dump\.age$' <<<"$raw_now") -eq 3 && $(grep -c '\.dump\.age\.ok$' <<<"$raw_now") -eq 3 ]] \
  || die "la retention laisse des objets orphelins dans le bucket : $raw_now"
grep -q 'in_progress' <<<"$raw_now" && die "un .in_progress reste apres des runs reussis : $raw_now"
ok "4 runs -> les 3 plus recents gardes, le plus ancien supprime"

# 2. Le dump se restaure hors de l'outil : age + pg_restore standards.
run get latest | docker run -i --rm --entrypoint age -v "$KEY:/key:ro" pgdump-age:test -d -i /key \
  | docker run -i --rm --network "$NET" -e PGPASSWORD=postgres postgres:18 \
      pg_restore -h postgres -U postgres -d app_restore --no-owner
rows=$(psql_pg -d app_restore -Atc 'select count(*) from items')
[[ $rows -eq 20000 ]] || die "restauration : attendu 20000 lignes, obtenu $rows"
ok "restauration complete (20000 lignes)"

# 3. Echec de connexion avec KEEP=1 : si la retention tournait apres un echec, elle supprimerait 2 dumps.
before=$(raw)
if PW=mauvais KEEP=1 run once >/dev/null 2>&1; then die "un mot de passe errone aurait du echouer"; fi
[[ $(raw) == "$before" ]] || die "le contenu du bucket a change apres un echec"
ok "echec de connexion (KEEP=1) : rien supprime, rien publie, aucun marqueur laisse"

# 4. Base inexistante : pg_dump echoue, age/rclone finissent normalement, le flux tronque est supprime.
if DB=nexiste_pas run once >/dev/null 2>&1; then die "une base inexistante aurait du echouer"; fi
raw | grep -q 'nexiste_pas' && die "un objet ou un marqueur reste pour une base inexistante"
[[ $(raw) == "$before" ]] || die "le contenu du bucket a change apres un pg_dump en echec"
ok "pg_dump en echec : aucun dump, aucun marqueur, rien supprime"

# 5. Run tue (.in_progress de plus d'un jour) : nettoyage limite a la base, au prefixe et a l'age.
echo x | rc rcat T:backups/other/app-20200101T000000Z.dump.age.in_progress
echo x | rc rcat T:backups/unrelated.dump.age.in_progress
echo x | rc rcat T:backups/app-20200101T000000Z.dump.age
echo x | rc rcat T:backups/app-20200101T000000Z.dump.age.in_progress
echo x | rc rcat T:backups/app-20200102T000000Z.dump.age
echo x | rc rcat T:backups/app-20200102T000000Z.dump.age.ok
echo x | rc rcat T:backups/app-20200102T000000Z.dump.age.in_progress
echo x | rc rcat T:backups/app-20991231T000000Z.dump.age
echo x | rc rcat T:backups/app-20991231T000000Z.dump.age.in_progress
for f in other/app-20200101T000000Z.dump.age.in_progress unrelated.dump.age.in_progress \
         app-20200101T000000Z.dump.age.in_progress app-20200102T000000Z.dump.age.in_progress; do
  rc touch -t 2020-01-01T00:00:00 "T:backups/$f"
done
KEEP=10 run once >/dev/null
files=$(rc lsf -R T:backups)
grep -q '^other/app-20200101T000000Z.dump.age.in_progress$' <<<"$files" || die "un .in_progress d'un autre prefixe a ete supprime"
grep -q '^unrelated.dump.age.in_progress$' <<<"$files"                    || die "un marqueur etranger a ete supprime"
grep -q '^app-20991231T000000Z.dump.age$' <<<"$files"                     || die "le dump d'un run recent a ete supprime"
grep -q '^app-20991231T000000Z.dump.age.in_progress$' <<<"$files"         || die "un .in_progress recent a ete supprime"
grep -q '^app-20200101T000000Z.dump.age' <<<"$files"                      && die "le dump interrompu (sans .ok) n'a pas ete nettoye avec son marqueur"
grep -q '^app-20200102T000000Z.dump.age$' <<<"$files"                     || die "un dump avec son .ok a ete supprime"
grep -q '^app-20200102T000000Z.dump.age.ok$' <<<"$files"                  || die "le .ok d'un dump a ete supprime"
grep -q '^app-20200102T000000Z.dump.age.in_progress$' <<<"$files"         && die "le marqueur d'un dump deja valide n'a pas ete supprime"
if run get app-20991231T000000Z.dump.age >/dev/null 2>&1; then die "get d'un dump sans .ok aurait du echouer"; fi
for f in other/app-20200101T000000Z.dump.age.in_progress unrelated.dump.age.in_progress \
         app-20200102T000000Z.dump.age app-20200102T000000Z.dump.age.ok \
         app-20991231T000000Z.dump.age app-20991231T000000Z.dump.age.in_progress; do
  rc deletefile "T:backups/$f"
done
ok "nettoyage des runs tues limite a la base, au prefixe et a l'age ; get refuse un dump sans .ok"

# 6. Prefixe S3 : le dump et son .ok atterrissent sous le prefixe, pas a la racine.
XENV=(-e S3_PREFIX=/sub/dir/); run once >/dev/null; XENV=()
[[ $(rc lsf T:backups/sub/dir | grep -c '\.dump\.age$') -eq 1 ]]    || die "dump absent sous le prefixe"
[[ $(rc lsf T:backups/sub/dir | grep -c '\.dump\.age\.ok$') -eq 1 ]] || die ".ok absent sous le prefixe"
rc purge T:backups/sub >/dev/null
ok "S3_PREFIX respecte"

# 7. Mode schedule : un .ok qui ne s'ecrit pas est un ERROR, jamais un "termine", et le dump reste invalide.
cat >"$WRAP" <<'WRAPPER'
#!/bin/sh
if [ "$1" = rcat ]; then
  for a; do last=$a; done
  case $last in *.ok) echo "echec simule de l'ecriture du .ok" >&2; exit 1 ;; esac
fi
exec /usr/bin/rclone "$@"
WRAPPER
chmod 755 "$WRAP"  # lisible et executable par l'uid 10001 du conteneur
before=$(run list | sort)
before_raw=$(raw)
build_args
docker run -d --name pgb-sched --read-only --tmpfs /tmp:size=8m "${ARGS[@]}" -e RUN_ON_START=1 \
  -v "$WRAP:/usr/local/bin/rclone:ro" pgdump-age:test schedule >/dev/null
for _ in $(seq 1 30); do
  docker logs pgb-sched 2>&1 | grep -q 'run de demarrage en echec' && break
  sleep 1
done
logs=$(docker logs pgb-sched 2>&1)
docker rm -f pgb-sched >/dev/null
grep -q 'ERROR.*publication.*impossible' <<<"$logs" || die "l'echec du .ok n'est pas journalise en ERROR: $logs"
grep -q 'termine :' <<<"$logs" && die "un .ok non ecrit est journalise comme une reussite"
[[ $(run list | sort) == "$before" ]] || die "un dump sans .ok est apparu dans list"
for f in $(comm -13 <(echo "$before_raw") <(raw)); do rc deletefile "T:backups/$f"; done
ok "schedule : .ok non ecrit -> ERROR, dump invisible pour list, retention intacte"

# Gros jeu de donnees pour les tests de flux (85 Mo apres compression).
psql_pg -d app -qc "CREATE TABLE big AS SELECT g AS id, md5(g::text) || md5((g*7)::text) AS a, md5((g*13)::text) AS b FROM generate_series(1, 1500000) g; GRANT SELECT ON big TO backup"

# 8. pg_dump tue en cours de flux : age/rclone finissent normalement, rien n'est publie.
before=$(raw)
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
[[ $(raw) == "$before" ]] || die "objet, marqueur ou suppression apres un pg_dump tue en cours de flux"
ok "pg_dump tue en cours de flux : rien publie, dump partiel et marqueur supprimes"

# 9. SIGTERM pendant un upload : arret rapide (pas de SIGKILL de docker), code 0.
XENV=(-e RCLONE_BWLIMIT=3M -e RUN_ON_START=1); build_args; XENV=()
docker run -d --name pgb-term --read-only --tmpfs /tmp:size=8m "${ARGS[@]}" pgdump-age:test schedule >/dev/null
sleep 6
start=$SECONDS
docker stop pgb-term >/dev/null
elapsed=$((SECONDS - start))
code=$(docker inspect -f '{{.State.ExitCode}}' pgb-term)
docker rm -f pgb-term >/dev/null
[[ $elapsed -lt 8 ]] || die "docker stop a mis ${elapsed}s : SIGTERM non propage (SIGKILL apres 10 s)"
[[ $code -eq 0 ]]    || die "code de sortie ${code} apres SIGTERM"
ok "SIGTERM pendant un upload : arret en ${elapsed}s, code 0"
# Le run tue laisse son .in_progress (jamais de .ok) : c'est lui qui permet de le reperer.
left=$(rc lsf T:backups | grep '\.in_progress$' || true)
[[ -n $left && $(wc -l <<<"$left") -eq 1 ]] || die "run tue : attendu 1 .in_progress, obtenu '$left'"
rc deletefile "T:backups/$left"

# 10. Upload multipart orphelin (conteneur tue) : nettoye au run suivant.
docker run -d --name pgb-orphan --network "$NET" --entrypoint sh -e RCLONE_CONFIG=/dev/null \
  -e RCLONE_CONFIG_T_TYPE=s3 -e RCLONE_CONFIG_T_PROVIDER=Other -e RCLONE_CONFIG_T_ENDPOINT=http://s3:9090 \
  -e RCLONE_CONFIG_T_REGION=us-east-1 -e RCLONE_CONFIG_T_ACCESS_KEY_ID=test \
  -e RCLONE_CONFIG_T_SECRET_ACCESS_KEY=test-secret -e RCLONE_CONFIG_T_NO_CHECK_BUCKET=true \
  -e RCLONE_S3_CHUNK_SIZE=5M pgdump-age:test \
  -c 'head -c 419430400 /dev/urandom | rclone rcat --bwlimit 4M T:backups/orphan.partial' >/dev/null
sleep 8
docker kill pgb-orphan >/dev/null; docker rm -f pgb-orphan >/dev/null
[[ $(multipart_open) -ge 1 ]] || die "l'upload orphelin n'a pas ete cree (test invalide)"
XENV=(-e MULTIPART_MAX_AGE=1s); run once >/dev/null; XENV=()
[[ $(multipart_open) -eq 0 ]] || die "l'upload multipart orphelin n'a pas ete nettoye"
ok "upload multipart orphelin nettoye au run suivant"

# 11. Gros dump : upload multipart en flux (parts de 5 Mio).
CHUNK=5M run once >/dev/null 2>&1 || die "echec du gros dump"
big=$(run list | grep '\.dump\.age$' | sort -t';' -k2 | tail -n1 | cut -d';' -f1)
[[ $big -gt 20000000 ]] || die "gros dump trop petit pour exercer le multipart ($big octets)"
psql_pg -qc "CREATE DATABASE app_restore_big"
run get latest | docker run -i --rm --entrypoint age -v "$KEY:/key:ro" pgdump-age:test -d -i /key \
  | docker run -i --rm --network "$NET" -e PGPASSWORD=postgres postgres:18 \
      pg_restore -h postgres -U postgres -d app_restore_big --no-owner \
  || die "restauration du gros dump en echec"
rows=$(psql_pg -d app_restore_big -Atc 'select count(*) from big')
[[ $rows -eq 1500000 ]] || die "gros dump : attendu 1500000 lignes, obtenu $rows"
ok "gros dump (${big} octets) en multipart, restaure (1500000 lignes)"

# 12. Plusieurs bases : un dump par base, retention par base, une base en echec n'arrete pas les autres.
psql_pg -d app2 -qc "CREATE TABLE items2 AS SELECT g AS id FROM generate_series(1, 100) g"
if DB="app, nexiste_pas ,app2" run once >/dev/null 2>&1; then die "une base inexistante dans PGDATABASES aurait du faire echouer le run"; fi
[[ $(run list | grep -c '^[0-9]*;app2-.*\.dump\.age$') -eq 1 ]] || die "app2 n'a pas ete dumpee malgre l'echec de la base precedente"
run list | grep -q 'nexiste_pas' && die "un objet a ete publie pour une base inexistante"
n_app=$(run list | grep -c ';app-.*\.dump\.age$')
DB=app,app2 KEEP=1 run once >/dev/null
[[ $(run list | grep -c ';app2-.*\.dump\.age$') -eq 1 && $(run list | grep -c ';app-.*\.dump\.age$') -eq 1 ]] \
  || die "retention par base: attendu 1 dump de app et 1 de app2 (app avait $n_app dumps)"
raw_now=$(raw)
for b in app app2; do
  [[ $(grep -c "^${b}-.*\.dump\.age$" <<<"$raw_now") -eq 1 && $(grep -c "^${b}-.*\.dump\.age\.ok$" <<<"$raw_now") -eq 1 ]] \
    || die "retention KEEP=1 : $b doit laisser exactement 1 dump et 1 .ok dans le bucket : $raw_now"
done
if DB=app,app2 run get latest >/dev/null 2>&1; then die "get latest sans base aurait du echouer avec deux bases"; fi
run get latest app2 | docker run -i --rm --entrypoint age -v "$KEY:/key:ro" pgdump-age:test -d -i /key \
  | docker run -i --rm --network "$NET" -e PGPASSWORD=postgres postgres:18 pg_restore -h postgres -U postgres -d app_restore --no-owner -t items2 \
  || die "restauration de app2 en echec"
[[ $(psql_pg -d app_restore -Atc 'select count(*) from items2') -eq 100 ]] || die "app2 : attendu 100 lignes"
for bad in "app,app" "app,,app2" "app;x"; do
  if DB="$bad" run once >/dev/null 2>&1; then die "PGDATABASES='$bad' aurait du etre refuse"; fi
done
ok "plusieurs bases : dump et retention par base, echec isole, get latest <base>, valeurs invalides refusees"

# 13. Metadonnees : .in_progress rafraichi avec les octets envoyes pendant le dump, .ok complet a la fin.
XENV=(-e RCLONE_BWLIMIT=6M -e PROGRESS_EVERY=2)
CHUNK=5M run once >/dev/null 2>&1 &
pid=$!
XENV=()
sleep 9
marker=$(rc lsf T:backups | grep '\.in_progress$' || true)
[[ -n $marker ]] || die "pas de .in_progress pendant le dump"
progress=$(rc cat "T:backups/$marker")
bytes=$(sed -n 's/^bytes=//p' <<<"$progress")
[[ $bytes =~ ^[0-9]+$ && $bytes -gt 0 ]] || die "progression nulle dans $marker : $progress"
grep -q '^db=app$' <<<"$progress" && grep -q '^started=' <<<"$progress" && grep -q '^updated=' <<<"$progress" \
  || die "metadonnees manquantes dans $marker : $progress"
wait "$pid" || die "le run chronometre a echoue"
dump=${marker%.in_progress}
rc lsf T:backups | grep -qx "$marker" && die ".in_progress toujours present apres le dump"
meta=$(rc cat "T:backups/$dump.ok")
size=$(sed -n 's/^size=//p' <<<"$meta")
actual=$(run list | grep ";${dump}$" | cut -d';' -f1)
[[ $size == "$actual" ]] || die ".ok: size=$size, objet=$actual"
for k in db name pghost started finished duration_s; do grep -q "^$k=" <<<"$meta" || die ".ok sans $k : $meta"; done
ok "metadonnees : progression ($bytes octets a mi-parcours) puis .ok complet (size, duree), .in_progress supprime"

# 14. Migration v0.1.1 : un dump sans .ok est invisible, `adopt` lui ecrit un .ok et supprime les .partial.
echo x | rc rcat T:backups/app-20190101T000000Z.dump.age
echo x | rc rcat T:backups/app-20190101T000000Z.dump.age.partial
listing=$(run list)
grep -q 'app-20190101T000000Z' <<<"$listing" && die "un dump sans .ok est visible dans list"
run adopt >/dev/null || die "adopt en echec"
listing=$(run list)
grep -q 'app-20190101T000000Z.dump.age$' <<<"$listing" || die "le dump adopte n'est pas visible apres adopt"
grep -q 'app-20190101T000000Z.dump.age.partial' <<<"$(raw)" && die "le .partial de v0.1.1 n'a pas ete supprime"
grep -q '^legacy=1$' <<<"$(rc cat T:backups/app-20190101T000000Z.dump.age.ok)" || die ".ok adopte sans legacy=1"
if run get 'app-*' >/dev/null 2>&1; then die "get avec un glob aurait du etre refuse"; fi
rc deletefile T:backups/app-20190101T000000Z.dump.age
rc deletefile T:backups/app-20190101T000000Z.dump.age.ok
ok "adopt : dump v0.1.1 adopte (legacy=1), .partial supprime ; get refuse un nom glob"

echo "tous les tests passent"
