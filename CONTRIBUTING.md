# Contribuer à pg-backup

Merci de votre intérêt. Le projet est volontairement petit : un script, une image, un test de bout en bout.

## Avant de commencer

- Ouvrez une issue pour une nouvelle fonctionnalité avant d'écrire du code. Les corrections de bug sont les bienvenues directement en pull request.
- Lisez [`CLAUDE.md`](CLAUDE.md) : il décrit les invariants à ne pas casser (c'est la référence, même si vous n'utilisez pas Claude).

## Lancer les tests

```sh
bash -n bin/pg-backup test/run.sh   # syntaxe
bash test/run.sh                    # bout en bout, Docker requis, environ 2 minutes
```

Tous les cas doivent passer. La CI exécute la même commande.

## Règles pour une pull request

- **Un garde-fou, un test qui échoue sans lui.** Si vous corrigez un défaut ou ajoutez une vérification, ajoutez le cas dans `test/run.sh`, puis réintroduisez le bug dans une copie du projet pour constater que le test devient rouge.
- **Toute nouvelle variable d'environnement** est validée dans `setup` et documentée dans le tableau du README.
- **Commits** : conventional commits (`feat:`, `fix:`, `docs:`...), atomiques.
- **Messages du script** (`log`, `warn`, `fail`) : sans accents, avec le préfixe `INFO`, `WARN` ou `ERROR`, car le monitoring les recherche.
- Pas de dépendance ajoutée pour quelques lignes de bash.

## Ce que le projet refuse volontairement

- Écrire le dump sur le disque, même temporairement.
- Un chiffrement symétrique, ou une clé privée dans l'image.
- Sauvegarder plusieurs bases dans un même conteneur.
- Publier directement sous le nom final, sans passer par `.partial`.
- Supprimer d'anciens dumps avant la fin d'un run réussi.

Si votre besoin entre dans cette liste, un autre outil (restic, pgBackRest, WAL-G) est probablement plus adapté.
