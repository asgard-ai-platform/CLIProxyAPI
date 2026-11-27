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
ones). When it stops it opens an issue labelled `asgard-sync` (once per problem, so there is no
flood), and the next run tries again from the same place. The first run that gets through closes
the open issues. It stops when:

- **the merge conflicts.** The attempt, with the conflict markers committed, is pushed to the
  branch `sync/v8.x.y`: a merge commit with two parents named
  `Merge upstream v8.x.y (UNRESOLVED CONFLICTS in <files>)`. See "Syncing by hand".
- **the gate fails.** `main` was not changed. The clean merge is pushed to `sync/v8.x.y` as
  `Merge upstream v8.x.y (verification failed, needs fixes)`. Fix the cause (or add a known
  upstream failure to the gate and to the list below), see "Syncing by hand".
- **the upstream release changes `.github/workflows/`.** A new upstream workflow would become
  active in this fork, and the built-in token cannot push workflow files, so there is no branch
  either. Merge it by hand and review the workflows first. This also applies to a workflow that
  is disabled in this fork, because the check looks at the diff, not at the Actions settings.
- **the image build fails.** The log of the `asgard-image` run says why; the next run retries, up
  to 3 failed builds of the tag.
- **upstream or GHCR cannot be read.** That is an error, never "nothing new": it opens an issue and
  it does not close the open ones.

The sync never overwrites an existing `sync/v8.x.y` branch (somebody may be working on it), and it
deletes the branch only once `main` contains it.

Only `v8.*` releases are followed. A new major version changes the module path, so it needs a
decision by hand; the run warns (and says so in its summary) when upstream has one.

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
  published image, because deployments pin the image digests. The check fails closed: only an
  HTTP 404 from GHCR lets the build go on, so a private package or an error of GHCR stops it
  loudly. There is one run per tag at a time. To rebuild an image on purpose, delete that version
  from GHCR first.
- The gate runs upstream code. It runs on an export of the merged commit in a temporary directory
  (not in the clone that is pushed) and without the token variables, so that code cannot add
  commits, plant git hooks or read the token from the environment, and the sync pushes exactly the
  commit that was verified. This is **not a sandbox**: code that runs in the same job on a
  GitHub-hosted runner can still reach whatever the runner itself can. Real isolation needs the
  merge and the gate in a job without write permissions and a second job that pushes. That is not
  done; upstream's code is also what the image runs in production.
- Image builds: when a build of a tag has failed 3 times, the sync stops starting new ones (each
  one is a full multi-arch build). Start it by hand with
  `gh workflow run asgard-image.yml --ref v8.x.y-asgard.1`. If the code has to change, the tag
  cannot be moved: push `v8.x.y-asgard.2` by hand on the fixed commit; the sync goes on once
  `v8.x.y` has any image.
- A run starts no new version after 240 minutes and leaves the rest for the next run, so it ends
  by itself instead of being killed by the job timeout.
- The issues need Issues to be enabled in this fork and the `issues: write` permission of the
  workflow. A sync that is stopped still fails every 30 minutes, so the Actions tab stays red until
  the cause is fixed, but the issue is opened only once.
- The published tags are read from GHCR without pagination (up to 1000 tags).

## Syncing by hand

Use this when the automatic sync stopped on a conflict or a failed gate, or to sync without it.

1. Fetch both remotes without losing tags:
   `git -c fetch.pruneTags=false fetch origin` and `git -c fetch.pruneTags=false fetch upstream --tags`.
   With `fetch.pruneTags=true` in your git config, every fetch deletes the local tags that the
   fetched remote does not have. `origin` only has our `-asgard.` tags and `upstream` only has the
   upstream ones, so each plain `git fetch` would wipe the other set. Either pass the `-c` flag
   or run `git config --local fetch.pruneTags false` once in your clone.
2. Start from `origin/main`, not from a local `main`, which may be behind because the automation
   pushes to it: `git switch -c sync/v8.0.N origin/main`, then
   `git merge --no-ff -m "Merge upstream v8.0.N" v8.0.N`. Merge the release tag, not `upstream/main`.
   After a stop, the branch `origin/sync/v8.0.N` already holds the attempt: start from it instead
   (`git switch -c sync/v8.0.N origin/sync/v8.0.N`) and find the markers with `git grep -n '<<<<<<<'`.
3. Resolve the conflicts: take upstream's side for everything that is not ours and re-apply our
   patch lines. `git diff v8.0.M..origin/main`, where `v8.0.M` is the upstream version `main` was
   based on, shows what the patch is. **Do all your changes inside the merge commit**:
   `git commit -a --amend -m "Merge upstream v8.0.N"`. The sync tags the oldest commit on the
   first-parent line of `main` that contains the upstream tag, which is that merge commit, so a
   fix in a separate commit on top would not be in the image.
4. Verify with the same gate as the automation: `bash .github/scripts/asgard-gate.sh`. It
   overwrites tracked catalog files, so restore them afterwards:
   `git checkout -- internal/registry/models`.
5. Check whether upstream added or changed files under `.github/workflows/`. Disable any new
   upstream workflow that runs on tags or pull requests (see Rules).
6. Fast-forward `main`: `git -c push.followTags=false push origin sync/v8.0.N:main`.
   Run it with `--dry-run` first and check that it updates only `main` and pushes no tag.
   Then push the resolved commit to the sync branch as well, so that the sync sees the branch as
   merged and deletes it: `git -c push.followTags=false push --force-with-lease origin sync/v8.0.N`.
   Otherwise delete the branch by hand.
7. **With the automation on, stop here.** The next run (or
   `gh workflow run asgard-sync.yml -f dry_run=false` right away) finds the version in `main`,
   creates the tag, builds the image and closes the issue.

Without the automation, also tag and push **one tag at a time** by name:
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
  `pr-path-guard.yml`, `agents-md-guard.yml` and `pr-test-build.yml` are disabled in the
  repository's Actions settings. `release.yaml` and `docker-image.yml` must stay disabled: tags
  matching `v*-asgard.*` would otherwise also trigger the upstream release and Docker Hub
  workflows. The other four only run on pull requests and are disabled because this fork does not
  need them.
- GitHub can also disable all the workflows of a fork on its own: the Actions page then shows
  "Workflows on this fork have been disabled", and the API still reports `enabled: true` and
  `active` for every workflow. On 2026-11-27 the page showed this banner and no workflow had run
  since 2026-11-21; it was enabled again with the button "I understand my workflows, go ahead and
  enable them". After enabling, run `gh workflow list --all` and check that the workflows above
  are still `disabled_manually`.
- Keep the Go module path `github.com/router-for-me/CLIProxyAPI/v8` unchanged. Renaming it would
  conflict on every merge.

## Known upstream test failures

Re-check this list on every sync.

- `internal/pluginhost`: `TestPluginErrorCarriesRetryAfterIntoCooldownAndHTTPHeader` fails
  deterministically at v8.0.74.
- `sdk/cliproxy`: `TestServiceHeartbeatFailoverDoesNotDrainBlockingScope` is flaky.
  It is skipped by `.github/scripts/asgard-gate.sh`.
- `sdk/cliproxy`: `TestPutOpenAICompatConcurrentWithAuthFieldsPatch_Issue6559` is flaky (a race in
  the registration of the management routes; it failed in about 1 to 2.5 percent of the runs when it
  was measured on 2 cores). It is skipped by `.github/scripts/asgard-gate.sh`.
- `internal/runtime/executor`: `TestAntigravityManagerExecuteAndStream_ToppedUpCreditsRecoverDuringQuotaCooldown`
  fails often at upstream v8.1.1 to v8.1.4 (a race in the recovery of the antigravity credits hint:
  about 25 of 100 runs on 2 cores and most runs on 1 core, on the plain upstream tags without our
  patch). It passes at v8.1.0 and from v8.1.5 on, where upstream fixed it in `41830213`. It is
  skipped by `.github/scripts/asgard-gate.sh`; remove it from the skip list once `main` contains
  v8.1.5.
- `internal/runtime/executor`: `TestAIStudioExecutorClaudeMalformedFunctionCallCancelAfterErrorRecordsConductorFailure`
  is flaky in every upstream version from v8.1.2 to v8.1.7 (it times out waiting for the conductor
  result; 10 to 30 failures in 100 runs on 2 cores). It is skipped by `.github/scripts/asgard-gate.sh`.
- `internal/registry`: `TestEmbeddedCodexClientModelsCatalogOmitsAudioForGPT62SolAndGPT55` (added
  in v8.1.3) asserts the content of the embedded Codex client models catalog, but the gate replaces
  that catalog with the current revision of the models repository before it runs the tests. It
  passes against the committed catalog and fails against the models repository revision `d02fed83`
  (2026-11-27, which lists audio input for `gpt-6.2-sol`) in every version tested, v8.1.4 to v8.1.7.
  It is skipped by `.github/scripts/asgard-gate.sh`.

Upstream v8.1.2 and v8.1.3 were never published as images. Their own tests fail on the plain
upstream tags (`TestIssue6825*`) and the tests of the package panic with a nil pointer dereference
in `GeminiVertexExecutor.executeStreamWithServiceAccount` (`scanner` is used before it is assigned).
Neither the failures nor the panic involve our patch. v8.1.4 showed no panic when it was tested, so
it is merged and tagged `v8.1.4-asgard.1` by hand. The sync never goes back to versions older than
the newest image, so it continues with v8.1.5 and does not publish v8.1.2 or v8.1.3.

## When upstream merges the Vertex Claude support

On the sync that brings it in, take upstream's version of every patch file
(`git checkout v8.0.N -- <file>`) and confirm that `git diff v8.0.N..HEAD --stat` only lists
`.github/workflows/asgard-image.yml` and this file. At that point consider dropping the fork.
