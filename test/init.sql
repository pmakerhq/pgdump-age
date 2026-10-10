CREATE ROLE backup LOGIN PASSWORD 'backup-pw';
GRANT pg_read_all_data TO backup;

CREATE TABLE items (id serial PRIMARY KEY, payload text NOT NULL);
INSERT INTO items (payload) SELECT md5(g::text) FROM generate_series(1, 20000) g;

CREATE DATABASE app_restore;
