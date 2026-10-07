FROM alpine:3.23

# postgresql18-client : pg_dump 18 (refuse de dumper un serveur plus recent, accepte les plus anciens).
RUN apk add --no-cache bash tini age rclone postgresql18-client \
  && adduser -D -u 10001 backup

COPY bin/pg-backup /usr/local/bin/pg-backup

USER backup
ENTRYPOINT ["/sbin/tini", "--", "pg-backup"]
CMD ["schedule"]
