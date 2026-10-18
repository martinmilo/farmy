# 2026-10-13 00:30 — Two expectations corrected after the worker's questions

The worker raised two questions (`work/QUESTIONS.md`, 2026-10-13) against the tests of
`2026-10-12-2350-farmy-cli.md`. Both were the tests' fault, not the program's; the decisions stand, the
observations change.

## 1. Database creation is observed by verb and name, not by an exact command

`createdb -U postgres hub_development` is a database being created. The expectation matched only
`createdb hub_development`. It now accepts anything between the verb and the name, and a
`CREATE DATABASE` statement as well.

Test altered: `start_test.rb` — "the databases named in create_databases_from are created in the service's
Postgres".

## 2. A Dockerfile build is observed through the builds, not through the container's image

Decided: with `dockerfile:`, farmy builds the named stage of the repository's Dockerfile with the
`build_files` in the context, and the container runs an image made **from** it. farmy's toolbox (the dev
user, the shell, the agent CLIs, the entrypoint) may be a layer on top, built from farmy's own Dockerfile.
So the image the container runs is not promised to be the stage build itself; what is promised is that the
stage build happened as described, and that the container runs. The tests now look at the builds Docker
was asked for (`assert_built target:, files:, dockerfile_includes:`) and still assert the container.

Tests altered: `build_from_repository_test.rb` — "a service with a dockerfile has the named stage built with
the files it copies", "the Dockerfile is read from the branch the manifest names", "rebuild builds the image
again from the Dockerfile as it is now". Helper renamed: `assert_built_for` → `assert_built`.
