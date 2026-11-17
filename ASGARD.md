# Asgard fork notes

This repository is a fork of [router-for-me/CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI)
maintained by asgard-ai-platform. Everything follows upstream except the items below.

`git diff v8.0.N..main` (where `v8.0.N` is the upstream release `main` is based on) shows exactly what we carry.

## What we carry

- **Vertex AI Anthropic (Claude) support.** Claude model IDs listed under
  `oauth.providers.vertex.claude-models` are routed to the Anthropic publisher endpoints
  (`:rawPredict` / `:streamRawPredict`) for Vertex auths that carry a service account.
  Upstream issue: router-for-me/CLIProxyAPI#7506 (closed as unplanned). Upstream PR: router-for-me/CLIProxyAPI#7507.
- `.github/workflows/asgard-image.yml`: builds and publishes the container image to GHCR.
- `.github/workflows/asgard-sync.yml` with `.github/scripts/asgard-sync.sh` (tests:
  `asgard-sync.test.sh`) and `.github/scripts/asgard-gate.sh`: follow upstream releases
  automatically, see "Automatic sync".
- This file.

## Branching and versions

- There is a single long-lived branch, `main` = one upstream release tag + our patches.
  There is no `dev` branch.
- Release tags are named `v<upstream version>-asgard.<n>`, for example `v8.0.74-asgard.1`.
  Pushing one builds and publishes `ghcr.io/asgard-ai-platform/cliproxyapi:<tag>`; the highest
  such tag also gets `:latest`.
- This repository (`origin`) only carries our `v*-asgard.*` tags. Upstream release tags
  (`v8.0.N`) live only on the `upstream` remote, so `git fetch upstream --tags` is what makes them
  available locally. That includes the `v8.0.N` in `git diff v8.0.N..main` above.

## Patch branch

`feat/vertex-claude-rawpredict` holds only the Vertex Claude patch on top of an upstream release
(currently v8.0.74): no CI workflow and no fork notes. It is a convenience export, for example to
diff the patch or to prepare an update to the upstream pull request. `main` is the source of truth
and never merges this branch.

Refresh it lazily, only when the patch changes or when you need it: recreate it from the upstream
release `main` is based on, cherry-pick the patch commits, and check that
`git diff feat/vertex-claude-rawpredict main --stat` lists only `.github/workflows/asgard-image.yml`
and `ASGARD.md`.

Upstream pull request router-for-me/CLIProxyAPI#7507 is left as it is for upstream.
Do not push fork-only changes (such as the moego JSON test fix) to its branch.

## Automatic sync

`asgard-sync.yml` runs at minutes 7 and 37 of every hour and follows the upstream releases. For
each upstream `v8.x.y` tag that is newer than the newest image on GHCR, oldest first:

1. merge the tag into `main` (`Merge upstream v8.x.y`), run the gate (`asgard-gate.sh`: build,
   vet and the tests of the packages the patch touches) and push `main`;
2. push the tag `v8.x.y-asgard.1`;
3. dispatch `asgard-image.yml` on that tag and wait until the image is published.

It does not matter how many releases came out between two runs: one run follows up to 8, and the
next run continues with the rest. Every step first looks at the real state, so a run that was
interrupted is resumed by the next one. A version only counts as followed once its image is on
GHCR, so a failed image build is retried and not forgotten. The automation never goes back to
versions older than the newest image.

It stops, and the run fails, instead of skipping a version (later versions contain the earlier
ones). The next run tries again from the same place. It stops when:

- **the merge conflicts.** Merge the tag by hand as in "Syncing by hand" up to step 5 and push
  `main`; the next run then creates the tag and builds the image.
- **the gate fails.** Nothing was pushed. Fix the cause, or add a known upstream failure to the
  gate and to the list below.
- **the upstream release changes `.github/workflows/`.** A new upstream workflow would become
  active in this fork, and the built-in token cannot push workflow files. Merge it by hand and
  review the workflows first.
- **the image build fails.** The log of the `asgard-image` run says why; the next run retries.

Only `v8.*` releases are followed. A new major version changes the module path, so it needs a
decision by hand.

Controls:

- Scheduled runs do nothing until the repository variable `ASGARD_SYNC_ENABLED` is `true`:
  `gh variable set ASGARD_SYNC_ENABLED --body true` to switch it on, `--body false` to pause it.
- A manual run (`gh workflow run asgard-sync.yml`) is a dry run by default: it merges and
  verifies but pushes and builds nothing. Add `-f dry_run=false` to do it for real.

Things to know:

- It uses the built-in `GITHUB_TOKEN`. Pushes made with that token do not start workflows, so the
  sync dispatches `asgard-image.yml` itself. With a personal access token the tag push would start
  the build as well, and the dispatch would have to go.
- `asgard-image.yml` refuses to run on anything but a `v*-asgard.*` tag and refuses to overwrite a
  published image, because deployments pin the image digests. To rebuild one on purpose, delete
  that version from GHCR first.
- The gate runs upstream code, so it runs without the token; the token is only given to git for
  the pushes.
- There is no notification besides the failed run in the Actions tab (issues are disabled in this
  fork). A sync that is stopped fails every 30 minutes until the cause is fixed.
- The published tags are read from GHCR without pagination (up to 1000 tags).

## Syncing by hand

1. `git -c fetch.pruneTags=false fetch upstream --tags`
   With `fetch.pruneTags=true` in your git config, every fetch deletes the local tags that the
   fetched remote does not have. `origin` only has our `-asgard.` tags and `upstream` only has the
   upstream ones, so each plain `git fetch` would wipe the other set. Either pass the `-c` flag
   as above or run `git config --local fetch.pruneTags false` once in your clone.
2. `git switch -c sync/v8.0.N main`, then `git merge --no-ff -m "Merge upstream v8.0.N" v8.0.N`.
   Merge the release tag, not `upstream/main`.
3. Resolve conflicts, then run `go build ./cmd/server` and the Vertex Claude tests
   (`go test -run VertexClaude ./internal/runtime/executor/ ./internal/config/ ./sdk/cliproxy/`).
4. Check whether upstream added or changed files under `.github/workflows/`. Disable any new
   upstream workflow that runs on tags or pull requests (see below).
5. Fast-forward `main`: `git -c push.followTags=false push origin sync/v8.0.N:main`.
   Run it with `--dry-run` first and check that it updates only `main` and pushes no tag.
6. Tag and push **one tag at a time** by name:
   `git tag -a v8.0.N-asgard.1 -m "..."` then
   `git -c push.followTags=false push origin refs/tags/v8.0.N-asgard.1`.
   Never use `--tags` or `--follow-tags`, and check with `--dry-run` first that exactly one tag is pushed.
   Before pushing the first tag, confirm that the upstream workflows listed under Rules are still disabled.
   Push the tag right after creating it and do not run `git fetch` in between: with
   `fetch.pruneTags=true` in your git config, a fetch deletes local tags that do not exist on the remote yet.
   Pushing a tag starts the image build; wait for it to succeed before pushing the next tag.

## Rules

- Do **not** use GitHub's "Sync fork" button. It merges upstream `main`, not a release tag.
- Squash merge and rebase merge are disabled in the repository settings; only merge commits are
  allowed. Never rewrite commits that contain upstream history, because it breaks the ancestry
  that later merges rely on.
- `main` is a protected branch: force pushes and deletion are blocked, and this also applies to
  admins. Pull requests are not required, so upstream syncs are fast-forwarded directly. To force
  push you must first remove the protection explicitly (and restore it afterwards).
- `push.followTags=true` in a global git config makes **every** push carry all annotated tags that
  the remote does not have yet, even when the command names a single tag or only a branch. Tags
  start the image build, so always pass `-c push.followTags=false` and use `--dry-run` first.
- The upstream workflows `release.yaml`, `docker-image.yml`, `auto-retarget-main-pr-to-dev.yml`,
  `pr-path-guard.yml` and `agents-md-guard.yml` are disabled in the repository's Actions settings.
  They must stay disabled: tags matching `v*-asgard.*` would otherwise also trigger the upstream
  release and Docker Hub workflows.
- Keep the Go module path `github.com/router-for-me/CLIProxyAPI/v8` unchanged. Renaming it would
  conflict on every merge.

## Known upstream test failures

Re-check this list on every sync.

- `internal/pluginhost`: `TestPluginErrorCarriesRetryAfterIntoCooldownAndHTTPHeader` fails
  deterministically at v8.0.74.
- `sdk/cliproxy`: `TestServiceHeartbeatFailoverDoesNotDrainBlockingScope` is flaky.
  It is skipped by `.github/scripts/asgard-gate.sh`.

## When upstream merges the Vertex Claude support

On the sync that brings it in, take upstream's version of every patch file
(`git checkout v8.0.N -- <file>`) and confirm that `git diff v8.0.N..HEAD --stat` only lists
`.github/workflows/asgard-image.yml` and this file. At that point consider dropping the fork.
