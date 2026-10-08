#!/usr/bin/env bash
# Objet de plus de 4,6 Gio contre un S3 reel (SeaweedFS) : upload multipart en flux, puis copie
# cote serveur (moveto) avec le seuil rclone par defaut. test/run.sh force un seuil de 5 Mo sur un
# petit dump et ne passe donc jamais par le vrai seuil. Lent et gourmand en disque (2 x SIZE_MIB) :
# hors CI de pull request, voir .github/workflows/s3-grand-objet.yml.
# SIZE_MIB=1024 COPY_CUTOFF=500M bash test/grand-objet.sh : version reduite pour un essai local.
set -euo pipefail
cd "$(dirname "$0")/.."

SIZE_MIB="${SIZE_MIB:-5120}"
want=$((SIZE_MIB * 1048576))
NET=pgb-grand
S3=pgb-grand-s3
CONF=$(mktemp)

cleanup() {
  docker rm -f "$S3" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  rm -f "$CONF"
}
trap cleanup EXIT

ok()  { echo "ok   - $*"; }
die() { echo "FAIL - $*" >&2; exit 1; }

cat >"$CONF" <<'JSON'
{"identities":[{"name":"t","credentials":[{"accessKey":"test","secretKey":"test-secret"}],
 "actions":["Admin","Read","Write","List","Tagging"]}]}
JSON
chmod 644 "$CONF"

docker build -q -t pgdump-age:test . >/dev/null
docker network create "$NET" >/dev/null
docker run -d --name "$S3" --network "$NET" -v "$CONF:/s3.json:ro" chrislusf/seaweedfs:latest \
  server -s3 -s3.config=/s3.json -dir=/data >/dev/null

# rclone de l'image, reglages par defaut de l'outil (parts de 32M x 2) : c'est ce que fait le dump.
rc() {
  docker run -i --rm --network "$NET" --entrypoint rclone -e RCLONE_CONFIG=/dev/null \
    -e RCLONE_CONFIG_T_TYPE=s3 -e RCLONE_CONFIG_T_PROVIDER=Other -e RCLONE_CONFIG_T_ENDPOINT="http://$S3:8333" \
    -e RCLONE_CONFIG_T_REGION=us-east-1 -e RCLONE_CONFIG_T_ACCESS_KEY_ID=test \
    -e RCLONE_CONFIG_T_SECRET_ACCESS_KEY=test-secret \
    -e RCLONE_S3_CHUNK_SIZE=32M -e RCLONE_S3_UPLOAD_CONCURRENCY=2 \
    ${COPY_CUTOFF:+-e RCLONE_S3_COPY_CUTOFF="$COPY_CUTOFF"} \
    pgdump-age:test "$@"
}

for _ in $(seq 30); do rc mkdir T:grand 2>/dev/null && break; sleep 2; done
rc lsf T: >/dev/null || die "S3 injoignable"
ok "S3 joignable, bucket cree"

# 1. Upload en flux, sans fichier local : meme chemin que rclone rcat dans le dump.
docker run --rm --network "$NET" --entrypoint sh -e RCLONE_CONFIG=/dev/null \
  -e RCLONE_CONFIG_T_TYPE=s3 -e RCLONE_CONFIG_T_PROVIDER=Other -e RCLONE_CONFIG_T_ENDPOINT="http://$S3:8333" \
  -e RCLONE_CONFIG_T_REGION=us-east-1 -e RCLONE_CONFIG_T_ACCESS_KEY_ID=test \
  -e RCLONE_CONFIG_T_SECRET_ACCESS_KEY=test-secret -e RCLONE_S3_CHUNK_SIZE=32M \
  pgdump-age:test -c "head -c $want /dev/urandom | rclone rcat T:grand/x.partial" \
  || die "upload multipart en echec"
got=$(rc size --json T:grand/x.partial | sed -n 's/.*"bytes":\([0-9]*\).*/\1/p')
[[ $got -eq $want ]] || die "taille apres upload : $got octets (attendu $want)"
ok "upload multipart en flux ($got octets)"

# 2. Renommage final = copie cote serveur avec le seuil par defaut (multipart au-dela de 4,6 Gio).
start=$SECONDS
log=$(rc moveto -vv T:grand/x.partial T:grand/x.bin 2>&1) || die "moveto en echec: $log"
elapsed=$((SECONDS - start))
grep -q "multipart copy with" <<<"$log" || die "moveto sans copie multipart (objet sous le seuil de copie ?)"
[[ $(rc size --json T:grand/x.bin | sed -n 's/.*"bytes":\([0-9]*\).*/\1/p') -eq $want ]] \
  || die "taille apres moveto differente"
[[ -z $(rc lsf T:grand/ | grep '\.partial$' || true) ]] || die ".partial toujours present apres moveto"
ok "moveto de $got octets en ${elapsed}s, taille identique, .partial disparu"

# 3. Listage des uploads multipart en cours (necessaire a 'rclone backend cleanup').
rc backend list-multipart-uploads T:grand >/dev/null || die "list-multipart-uploads en echec"
rc backend cleanup T:grand >/dev/null || die "backend cleanup en echec"
ok "list-multipart-uploads et cleanup"

echo "tous les tests passent"
