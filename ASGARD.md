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
- This file.

## Branching and versions

- There is a single long-lived branch, `main` = one upstream release tag + our patches.
  There is no `dev` branch.
- Release tags are named `v<upstream version>-asgard.<n>`, for example `v8.0.74-asgard.1`.
  Pushing one builds and publishes `ghcr.io/asgard-ai-platform/cliproxyapi:<tag>`; the highest
  such tag also gets `:latest`.

## Syncing a new upstream release

1. `git fetch upstream --tags`
2. `git switch -c sync/v8.0.N main`, then `git merge --no-ff -m "Merge upstream v8.0.N" v8.0.N`.
   Merge the release tag, not `upstream/main`.
3. Resolve conflicts, then run `go build ./cmd/server` and the Vertex Claude tests
   (`go test -run VertexClaude ./internal/runtime/executor/ ./internal/config/ ./sdk/cliproxy/`).
4. Check whether upstream added or changed files under `.github/workflows/`. Disable any new
   upstream workflow that runs on tags or pull requests (see below).
5. Fast-forward `main`: `git push origin sync/v8.0.N:main`.
6. Tag and push **one tag at a time** by name:
   `git tag -a v8.0.N-asgard.1 -m "..."` then `git push origin v8.0.N-asgard.1`.
   Never use `--tags` or `--follow-tags`.
   Push the tag right after creating it and do not run `git fetch` in between: with
   `fetch.pruneTags=true` in your git config, a fetch deletes local tags that do not exist on the remote yet.

## Rules

- Do **not** use GitHub's "Sync fork" button. It merges upstream `main`, not a release tag.
- Do **not** squash or rebase merge anything that contains upstream commits. It rewrites them and
  breaks the ancestry that later merges rely on. Only our own changes may be squashed.
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
  It is skipped by the release workflow.

## When upstream merges the Vertex Claude support

On the sync that brings it in, take upstream's version of every patch file
(`git checkout v8.0.N -- <file>`) and confirm that `git diff v8.0.N..HEAD --stat` only lists
`.github/workflows/asgard-image.yml` and this file. At that point consider dropping the fork.
