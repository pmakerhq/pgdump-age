# Contributing to pgdump-age

Thanks for your interest. The project is deliberately small: one script, one image, one end-to-end test.

## Before you start

- Open an issue before writing code for a new feature. Bug fixes are welcome directly as pull requests.
- Read [`CLAUDE.md`](CLAUDE.md): it describes the invariants not to break (it is the reference, even if you do not use Claude). It is written in French.

## Running the tests

```sh
bash -n bin/pgdump-age test/run.sh   # syntax only
bash test/run.sh                    # end to end, Docker required, about 2 minutes
```

Every case must pass. CI runs the same command.

## Pull request rules

- **One safeguard, one test that fails without it.** If you fix a defect or add a check, add the case to `test/run.sh`, then reintroduce the bug in a copy of the project and confirm the test turns red.
- **Every new environment variable** is validated in `setup` and documented in the README table.
- **Commits**: conventional commits (`feat:`, `fix:`, `docs:`...), atomic.
- **Script messages** (`log`, `warn`, `fail`): in French without accents, prefixed `INFO`, `WARN` or `ERROR`, because monitoring searches for them. Do not translate them: alerts may depend on the exact text.
- No new dependency for a few lines of bash.

## Releasing

Maintainers only. Run the `/release` skill ([`.claude/skills/release/SKILL.md`](.claude/skills/release/SKILL.md)): it tags `main` as `vX.Y.Z` and pushes the tag, which triggers the image build and publication on ghcr.io. Never move or delete a pushed tag: publish a new patch.

## What the project deliberately refuses

- Writing the dump to disk, even temporarily.
- Symmetric encryption, or a private key in the image.
- Backing up several databases in one container.
- Treating a dump as valid without its `.ok` file.
- Deleting old dumps before a run has fully succeeded.

If your need is on this list, another tool (restic, pgBackRest, WAL-G) is probably a better fit.
