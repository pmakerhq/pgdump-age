---
name: release
description: Cree un tag de version vX.Y.Z sur main et le pousse, ce qui declenche la publication de l'image Docker sur ghcr.io. A utiliser pour "release", "nouvelle version", "tag", "publier l'image".
disable-model-invocation: true
---

# Release

Un tag `vX.Y.Z` poussé sur GitHub déclenche `.github/workflows/image.yml` : tests de bout en bout, puis publication de `ghcr.io/<owner>/pgdump-age:vX.Y.Z`. Ce skill crée et pousse le tag, rien d'autre. Il ne modifie aucun fichier.

## Étapes

1. **Contrôles** (s'arrêter au premier échec, ne rien corriger sans demander) :
   - `git branch --show-current` vaut `main`.
   - `git status --porcelain` est vide.
   - `git fetch origin main --tags`, puis `git rev-parse HEAD` égal `git rev-parse origin/main` (rien de non poussé, rien en retard).
   - Si `bin/pgdump-age` ou `Dockerfile` ont changé depuis le dernier tag, `bash test/run.sh` doit passer ici. Le workflow le rejoue, mais un tag poussé ne se reprend pas proprement.
2. **Version** : dernier tag `git describe --tags --abbrev=0 --match 'v*'` (aucun : `v0.1.0`). Lire `git log <tag>..HEAD --oneline` et proposer le prochain numéro selon les conventional commits : `feat` donne mineur, `fix`/`perf` donne patch, `!` ou `BREAKING CHANGE` donne majeur (tant que `v0.x`, un changement cassant donne aussi un mineur). Si seuls `docs`/`chore`/`test`/`ci` : demander s'il y a vraiment lieu de publier. L'utilisateur peut imposer un numéro ; il doit respecter `^v[0-9]+\.[0-9]+\.[0-9]+$` et ne pas exister déjà.
3. **Confirmer** : afficher le tag, les commits inclus et la cible (`origin`). Pousser un tag est visible de l'extérieur et déclenche une publication : attendre un oui explicite avant l'étape 4.
4. **Tag annoté et push** :
   ```
   git tag -a vX.Y.Z -m "vX.Y.Z" -m "<résumé des commits, une ligne par changement notable>"
   git push origin vX.Y.Z
   ```
   Ne jamais déplacer ni supprimer un tag déjà poussé : publier un nouveau patch.
5. **Suivi** : `gh run watch` sur le run du tag si `gh` est disponible, sinon donner l'URL `https://github.com/<owner>/pgdump-age/actions`. Rapporter le résultat tel quel (digest du résumé du run en cas de succès, étape en échec sinon). Rappeler que le paquet ghcr doit être public pour un `docker pull` sans login.

## Règles

- Jamais depuis une autre branche que `main`, jamais avec un arbre sale.
- Pas de `--force`, pas de `git push --tags` (ne pousser que le tag créé).
- Ne pas affirmer que l'image est publiée avant d'avoir vu le run réussir.
