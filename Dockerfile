FROM alpine:3.23

# postgresql18-client : pg_dump 18 (refuse de dumper un serveur plus recent, accepte les plus anciens).
RUN apk add --no-cache bash tini age rclone postgresql18-client \
  && adduser -D -u 10001 backup

COPY bin/pgdump-age /usr/local/bin/pgdump-age

USER backup
# -g : SIGTERM va a tout le groupe (pg_dump, age, rclone), pas seulement a bash, sinon docker stop
# attend 10 s puis tue le conteneur en plein upload.
ENTRYPOINT ["/sbin/tini", "-g", "--", "pgdump-age"]
CMD ["schedule"]
