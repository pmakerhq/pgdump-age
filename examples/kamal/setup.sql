-- Role de sauvegarde en lecture seule. A executer en superuser sur la base a sauvegarder.
-- Choisir un mot de passe sans caractere special d'URL (@ : / % # ?), par exemple alphanumerique.
CREATE ROLE backup LOGIN PASSWORD 'CHANGE-ME';

-- Lecture de toutes les tables, vues et sequences de tous les schemas.
GRANT pg_read_all_data TO backup;

-- Verification (attendu : t) :
--   SELECT pg_has_role('backup', 'pg_read_all_data', 'member');
--
-- Si une table a la securite par ligne (row-level security) activee, pg_dump echouera pour ce
-- role : lui donner BYPASSRLS (ALTER ROLE backup BYPASSRLS) ou sauvegarder avec un role proprietaire.
-- Le pg_hba.conf du serveur doit aussi autoriser ce role depuis l'hote de l'accessory.
