# Politique de sécurité

## Signaler une vulnérabilité

**N'ouvrez pas d'issue publique.** Utilisez les *Security Advisories* de GitHub (onglet *Security*, puis *Report a vulnerability*) pour un signalement privé.

Indiquez la version de l'image (tag ou digest), les conditions de reproduction et l'impact. Un accusé de réception est envoyé dès que possible ; il n'y a pas de délai garanti.

## Versions supportées

Seule la dernière version publiée est corrigée.

## Modèle de menace

- Le serveur de sauvegarde ne détient que la **clé publique** age : une fuite de son environnement ne permet pas de déchiffrer les sauvegardes existantes.
- Les secrets (`PGPASSWORD`, clés S3) transitent par l'environnement du conteneur, jamais par la ligne de commande.
- Le conteneur tourne sans privilèges (utilisateur 10001) et fonctionne avec un système de fichiers en lecture seule.

## Hors périmètre

- La perte de la clé privée age rend les sauvegardes irrécupérables : c'est le comportement attendu, pas une vulnérabilité.
- Le comportement face à un fournisseur S3 compromis ou malveillant : l'outil ne vérifie pas l'intégrité des objets après envoi au-delà de ce que garantit S3.
- Les vulnérabilités des paquets Alpine, `age`, `rclone` et `pg_dump` embarqués : signalez-les en amont, puis ici si une mise à jour de l'image est nécessaire.
