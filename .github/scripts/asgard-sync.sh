#!/usr/bin/env bash
# Follow upstream releases (see ASGARD.md, "Automatic sync").
#
# For every upstream release tag v<major>.x.y that is newer than the newest published asgard
# image, oldest first:
#   1. merge the tag into main, verify the result and push main;
#   2. create and push the tag v<version>-asgard.1;
#   3. build the image (asgard-image.yml dispatched on that tag) and wait until it is published.
#
# Every step first looks at the real state (git refs, GHCR), so a run that stopped half way is
# simply resumed by the next run. The script stops at the first problem instead of skipping a
# version: later versions contain the earlier ones, so skipping would hide the problem.
#
# When it stops it opens an issue (once per problem, labelled asgard-sync) and, when a human has to
# edit code (merge conflict, failed verification), pushes the merge attempt to the branch
# sync/<version>. The next run that gets through closes the open issues and deletes the branch
# once it is merged.
#
# The script resets the work tree, so it only runs in GitHub Actions, or with ASGARD_ALLOW_LOCAL=1
# (used by asgard-sync.test.sh).
set -euo pipefail

UPSTREAM_URL="${ASGARD_UPSTREAM_URL:-https://github.com/router-for-me/CLIProxyAPI.git}"
MAJOR="${ASGARD_MAJOR:-v8}"
BRANCH="${ASGARD_BRANCH:-main}"
MAX_VERSIONS="${ASGARD_MAX_VERSIONS:-8}"
DRY_RUN="${ASGARD_DRY_RUN:-false}"
POLL_SECONDS="${ASGARD_POLL_SECONDS:-30}"
BUILD_TIMEOUT_MINUTES="${ASGARD_BUILD_TIMEOUT_MINUTES:-60}"
# After this many failed builds of a tag the sync stops starting new ones.
MAX_BUILD_ATTEMPTS="${ASGARD_MAX_BUILD_ATTEMPTS:-3}"
# No new version is started after this many minutes; the next run goes on. The job timeout of the
# workflow has to leave room for one more version (gate and build) after this.
TIME_BUDGET_MINUTES="${ASGARD_TIME_BUDGET_MINUTES:-240}"
REPO_SLUG="${GITHUB_REPOSITORY:-asgard-ai-platform/CLIProxyAPI}"
GHCR_REPO="$(printf '%s' "$REPO_SLUG" | tr '[:upper:]' '[:lower:]')"
ISSUE_LABEL="asgard-sync"
# GHCR answers 404 to a manifest request whose Accept does not match the manifest, so ask for all
# the types an image can have. Otherwise an image of another type would look as if it was missing.
MANIFEST_ACCEPT="application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json"
START_TS="$(date +%s)"

if [[ "${GITHUB_ACTIONS:-}" != "true" && "${ASGARD_ALLOW_LOCAL:-}" != "1" ]]; then
  echo "refusing to run outside GitHub Actions: this script resets the work tree" >&2
  exit 2
fi

# The version that is being followed; it ends up in the title of the issue.
CURRENT=""
# The branch the merge attempt was pushed to, set by push_attempt_branch.
ATTEMPT_BRANCH=""

log() { printf '%s\n' "$*" >&2; }

summary() {
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf '%s\n' "$*" >> "$GITHUB_STEP_SUMMARY"
  fi
}

die() {
  log "::error::$*"
  summary "### Sync stopped"
  summary ""
  summary "$*"
  exit 1
}

is_dry() { [[ "$DRY_RUN" == "true" ]]; }

# version_gt A B: true when version A is strictly newer than version B.
version_gt() {
  [[ "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" == "$1" ]]
}

# ---- state lookups (replaceable through $ASGARD_HOOKS in tests) ----------------------------

upstream_versions() {
  git ls-remote --tags --refs "$UPSTREAM_URL" "refs/tags/${MAJOR}.*" \
    | sed 's#.*refs/tags/##' \
    | { grep -E "^${MAJOR}\.[0-9]+\.[0-9]+\$" || true; } \
    | sort -V
}

# The highest upstream major version, to tell when upstream has moved on. Best effort.
upstream_top_major() {
  git ls-remote --tags --refs "$UPSTREAM_URL" 2> /dev/null \
    | sed 's#.*refs/tags/##' \
    | { grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' || true; } \
    | cut -d. -f1 \
    | sort -V \
    | tail -n 1
}

ghcr_token() {
  curl -fsS "https://ghcr.io/token?scope=repository:${GHCR_REPO}:pull" | jq -r '.token // empty'
}

# Tags of the published images, e.g. v8.0.74-asgard.1. Needs the package to be public.
published_asgard_tags() {
  local token
  token="$(ghcr_token)" || return 1
  [[ -n "$token" ]] || return 1
  curl -fsS -H "Authorization: Bearer ${token}" "https://ghcr.io/v2/${GHCR_REPO}/tags/list?n=1000" \
    | jq -r '.tags[]?' \
    | { grep -E "^${MAJOR}\.[0-9]+\.[0-9]+-asgard\.[0-9]+\$" || true; }
}

# image_exists TAG: 0 when the image is published, 1 when it is not, 2 when GHCR cannot tell.
image_exists() {
  local token code
  token="$(ghcr_token)" || return 2
  code="$(curl -s -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer ${token}" \
    -H "Accept: ${MANIFEST_ACCEPT}" \
    "https://ghcr.io/v2/${GHCR_REPO}/manifests/$1")" || return 2
  case "$code" in
    200) return 0 ;;
    404) return 1 ;;
    *) return 2 ;;
  esac
}

# Prints "<id> <status> <conclusion>" of the newest asgard-image run on the tag, or nothing.
latest_run() {
  gh run list --repo "$REPO_SLUG" --workflow asgard-image.yml --branch "$1" --limit 1 \
    --json databaseId,status,conclusion \
    --jq '.[0] | select(. != null) | "\(.databaseId) \(.status) \(.conclusion)"'
}

# Prints how many runs of asgard-image on the tag did not succeed.
failed_runs() {
  gh run list --repo "$REPO_SLUG" --workflow asgard-image.yml --branch "$1" --limit 20 \
    --json conclusion \
    --jq '[.[] | select(.conclusion == "failure" or .conclusion == "cancelled" or .conclusion == "timed_out")] | length'
}

dispatch_build() {
  gh workflow run asgard-image.yml --repo "$REPO_SLUG" --ref "$1" > /dev/null
}

# The gate runs upstream code (go test, go run), so it does not run in the clone that is pushed.
# It runs on an export of the merged commit in a temporary directory, with the token variables
# removed. That way the code cannot add commits, plant git hooks or change the config of the clone.
# It is not a sandbox, see ASGARD.md. The directory is left to the runner, which wipes it.
run_gate() {
  local merged tmp
  merged="$(git rev-parse HEAD)"
  tmp="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/asgard-gate.XXXXXX")"
  git archive "$merged" | tar -x -C "$tmp" || return 1
  # The models refresh fetches with git, so the copy gets an empty repository of its own.
  git -C "$tmp" init -q || return 1
  (
    cd "$tmp" || exit 1
    # shellcheck disable=SC2086  # ASGARD_GATE_COMMAND is a command line, split on purpose
    env -u GH_TOKEN -u GITHUB_TOKEN -u ASGARD_GIT_AUTH -u GIT_CONFIG_PARAMETERS -u GITHUB_OUTPUT \
      -u ACTIONS_RUNTIME_TOKEN -u ACTIONS_ID_TOKEN_REQUEST_TOKEN -u ACTIONS_ID_TOKEN_REQUEST_URL \
      ${ASGARD_GATE_COMMAND:-bash .github/scripts/asgard-gate.sh}
  )
}

git_push() {
  if [[ -n "${ASGARD_GIT_AUTH:-}" ]]; then
    git -c "$ASGARD_GIT_AUTH" -c push.followTags=false push "$@"
  else
    git -c push.followTags=false push "$@"
  fi
}

# push_or_stop KIND MESSAGE ARGS...: push, and when that fails put the end of what git said into
# the report, because that is where the reason is (a protected branch, a workflow file).
push_or_stop() {
  local kind="$1" message="$2" out
  shift 2
  if ! out="$(git_push "$@" 2>&1)"; then
    out="$(printf '%s\n' "$out" | { grep -v -i -E 'authorization|x-access-token' || true; } | tail -n 5)"
    stop "$kind" "${message}: ${out}"
  fi
}

# report_issue TITLE BODY: open an issue unless one with the same title is already open.
report_issue() {
  if is_dry; then
    return 0
  fi
  gh label create "$ISSUE_LABEL" --repo "$REPO_SLUG" --color D93F0B \
    --description "asgard-sync stopped and needs a human" > /dev/null 2>&1 || true
  if [[ -n "$(gh issue list --repo "$REPO_SLUG" --label "$ISSUE_LABEL" --state open \
    --search "\"$1\" in:title" --json number --jq '.[0].number // empty')" ]]; then
    return 0
  fi
  gh issue create --repo "$REPO_SLUG" --label "$ISSUE_LABEL" --title "$1" --body "$2" > /dev/null
}

# close_issues: the run got through, so whatever stopped the earlier runs is gone. Only the issues
# that asgard-sync opened are closed, a person may have used the label too.
close_issues() {
  local n
  if is_dry; then
    return 0
  fi
  for n in $(gh issue list --repo "$REPO_SLUG" --label "$ISSUE_LABEL" --state open \
    --json number,title \
    --jq '.[] | select(.title | startswith("asgard-sync stopped")) | .number' 2> /dev/null); do
    gh issue close "$n" --repo "$REPO_SLUG" \
      --comment "Resolved: the latest asgard-sync run went through without stopping." > /dev/null 2>&1 || true
  done
}

# stop KIND MESSAGE: report the problem (issue and run summary) and end the run.
stop() {
  local kind="$1" message="$2" title body
  title="asgard-sync stopped${CURRENT:+ at ${CURRENT}}: ${kind}"
  body="${message}"$'\n\n'"Run: ${GITHUB_SERVER_URL:-https://github.com}/${REPO_SLUG}/actions/runs/${GITHUB_RUN_ID:-0}"
  body="${body}"$'\n\n'"What to do: https://github.com/${REPO_SLUG}/blob/${BRANCH}/ASGARD.md#automatic-sync"
  body="${body}"$'\n\n'"The sync tries again every 30 minutes by itself. Once it gets through it closes this issue."
  report_issue "$title" "$body" || log "::warning::could not open the issue \"${title}\""
  die "$message"
}

# have_image TAG: true when the image is published, false when it is not. When GHCR cannot tell,
# the run stops: guessing "missing" could start a second build of an image that exists.
have_image() {
  local rc=0
  image_exists "$1" || rc=$?
  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
    *) stop "cannot read GHCR" "cannot tell whether the image $1 is published: GHCR answered with neither 200 nor 404" ;;
  esac
}

# build_image TAG: dispatch the image build for the tag (or join the run that is already
# going) and wait until it has published the image.
build_image() {
  local tag="$1" line id status conclusion prev_id="" tries=0 deadline failures
  CURRENT="${CURRENT:-$tag}"

  if have_image "$tag"; then
    log "image $tag is already published"
    return 0
  fi

  # A failing lookup must not look like "no run yet": that would start a second build.
  line="$(latest_run "$tag")" || stop "cannot list runs" "cannot list the runs of the image build for $tag"
  id=""; status=""; conclusion=""
  read -r id status conclusion <<< "$line" || true

  if [[ -n "$id" && "$status" != "completed" ]]; then
    log "the image build for $tag is already running (run $id)"
  else
    failures="$(failed_runs "$tag")" || stop "cannot list runs" "cannot list the runs of the image build for $tag"
    if [[ "${failures:-0}" -ge "$MAX_BUILD_ATTEMPTS" ]]; then
      stop "image build failed" "the image build for $tag failed ${failures} times, so the sync does not start another one. Fix the cause and start it by hand (gh workflow run asgard-image.yml --ref ${tag}). If the code has to change, publish ${tag%-asgard.*}-asgard.2 by hand instead (see ASGARD.md). The sync goes on once that version has an image."
    fi
    prev_id="$id"
    dispatch_build "$tag" || stop "image build could not start" "cannot start the image build for $tag"
    while :; do
      line="$(latest_run "$tag")" || line=""
      id=""; status=""; conclusion=""
      read -r id status conclusion <<< "$line" || true
      if [[ -n "$id" && "$id" != "$prev_id" ]]; then
        break
      fi
      tries=$((tries + 1))
      if [[ $tries -gt 20 ]]; then
        stop "image build did not start" "the image build for $tag did not start"
      fi
      sleep "$POLL_SECONDS"
    done
    log "started the image build for $tag (run $id)"
  fi

  deadline=$(( $(date +%s) + BUILD_TIMEOUT_MINUTES * 60 ))
  while [[ "$status" != "completed" ]]; do
    if [[ $(date +%s) -ge $deadline ]]; then
      stop "image build timed out" "the image build for $tag (run $id) did not finish within ${BUILD_TIMEOUT_MINUTES} minutes; the next run picks it up"
    fi
    sleep "$POLL_SECONDS"
    line="$(latest_run "$tag")" || line=""
    id=""; status=""; conclusion=""
    read -r id status conclusion <<< "$line" || true
  done

  if [[ "$conclusion" != "success" ]]; then
    # Another run of the same tag may have published the image first; this one then fails its guard.
    if have_image "$tag"; then
      log "run $id ended with '${conclusion}', but the image $tag is published"
      return 0
    fi
    stop "image build failed" "the image build for $tag finished with '${conclusion}' (run $id); fix the cause, then the next run retries it"
  fi
  have_image "$tag" || stop "image missing after build" "the image build for $tag succeeded but the image is not on GHCR"
}

if [[ -n "${ASGARD_HOOKS:-}" ]]; then
  # shellcheck disable=SC1090
  source "$ASGARD_HOOKS"
fi

# ---- sync ----------------------------------------------------------------------------------

DONE_LINES=()

# push_attempt_branch V WHY: commit the current merge attempt (conflicted or failed) and push it to
# sync/V, so that a human can continue from it. The commit message differs from "Merge upstream V"
# on purpose, so that nothing mistakes it for the finished merge. An existing branch is never
# overwritten, somebody may be working on it. Sets ATTEMPT_BRANCH when there is a branch.
push_attempt_branch() {
  local v="$1" why="$2" branch="sync/$1" msg
  msg="Merge upstream ${v} (${why})"
  ATTEMPT_BRANCH=""
  if is_dry; then
    return 0
  fi
  if git ls-remote --exit-code --heads origin "refs/heads/${branch}" > /dev/null 2>&1; then
    ATTEMPT_BRANCH="${branch} (it already exists and was left untouched)"
    return 0
  fi
  if [[ -e "$(git rev-parse --git-path MERGE_HEAD)" ]]; then
    git add -A > /dev/null 2>&1 || return 0
    git commit -q -m "$msg" > /dev/null 2>&1 || return 0
  else
    git commit -q --amend -m "$msg" > /dev/null 2>&1 || return 0
  fi
  if git_push origin "HEAD:refs/heads/${branch}" > /dev/null 2>&1; then
    ATTEMPT_BRANCH="$branch"
  else
    log "::warning::could not push the merge attempt to ${branch}"
  fi
}

# delete_merged_attempt_branch V: remove sync/V from origin once main contains it.
delete_merged_attempt_branch() {
  local branch="sync/$1"
  if is_dry; then
    return 0
  fi
  git ls-remote --exit-code --heads origin "refs/heads/${branch}" > /dev/null 2>&1 || return 0
  git fetch --no-tags -q origin "+refs/heads/${branch}:refs/remotes/origin/${branch}" > /dev/null 2>&1 || return 0
  if git merge-base --is-ancestor "refs/remotes/origin/${branch}" HEAD; then
    if git_push origin --delete "$branch" > /dev/null 2>&1; then
      log "deleted the merged branch ${branch}"
    fi
  fi
}

# first_commit_containing V: the oldest commit on the first-parent line of HEAD that contains the
# upstream tag V. For a merge that is the merge commit, however it was named. Whatever was added
# on top of it later is not part of the version, and the version never includes a later one.
# HEAD has to contain the tag. The first-parent line is monotonic, so a bisection finds it.
first_commit_containing() {
  local list=() c lo hi mid
  while IFS= read -r c; do
    list+=("$c")
  done < <(git rev-list --first-parent --reverse HEAD)
  lo=0
  hi=$((${#list[@]} - 1))
  while [[ $lo -lt $hi ]]; do
    mid=$(((lo + hi) / 2))
    if git merge-base --is-ancestor "refs/tags/$1" "${list[mid]}"; then
      hi=$mid
    else
      lo=$((mid + 1))
    fi
  done
  printf '%s\n' "${list[lo]}"
}

# follow_version V: bring main, the tag and the image up to upstream release V.
follow_version() {
  local v="$1" tag="$1-asgard.1" before merged changed conflicts target
  CURRENT="$v"

  log "== following upstream $v"
  git fetch --no-tags -q "$UPSTREAM_URL" "+refs/tags/${v}:refs/tags/${v}" \
    || stop "cannot fetch the upstream tag" "cannot fetch the upstream tag $v"

  if git merge-base --is-ancestor "refs/tags/${v}" HEAD; then
    log "$BRANCH already contains $v"
  else
    before="$(git rev-parse HEAD)"
    if ! git merge --no-ff -q -m "Merge upstream ${v}" "refs/tags/${v}" > /dev/null 2>&1; then
      conflicts="$(git diff --name-only --diff-filter=U | tr '\n' ' ')"
      push_attempt_branch "$v" "UNRESOLVED CONFLICTS in ${conflicts% }"
      git reset --hard -q "$before"
      git clean -fdq
      stop "merge conflict" "merging upstream ${v} into ${BRANCH} conflicts in: ${conflicts:-unknown files}.${ATTEMPT_BRANCH:+ The attempt, with the conflict markers committed, is on the branch ${ATTEMPT_BRANCH}.} Resolve it as described in ASGARD.md (\"Syncing by hand\"); the next run continues from there."
    fi
    merged="$(git rev-parse HEAD)"

    changed="$(git diff --name-status "$before" "$merged" -- .github/workflows | tr '\n' ' ')"
    if [[ -n "$changed" ]]; then
      git reset --hard -q "$before"
      stop "upstream changes workflows" "upstream ${v} changes .github/workflows (${changed}). A new upstream workflow would become active in this fork, and the built-in token cannot push workflow files, so merge ${v} by hand and review the workflows first (see ASGARD.md)."
    fi

    if ! run_gate; then
      push_attempt_branch "$v" "verification failed, needs fixes"
      git reset --hard -q "$before"
      git clean -fdq
      stop "verification failed" "the verification of the merge with upstream ${v} failed; see the log of this run.${ATTEMPT_BRANCH:+ The merge is on the branch ${ATTEMPT_BRANCH}.} ${BRANCH} was not changed."
    fi
    # What is pushed is exactly what was verified.
    if [[ "$(git rev-parse HEAD)" != "$merged" ]]; then
      git reset --hard -q "$before"
      stop "verification failed" "the work tree changed during the verification of upstream ${v}; ${BRANCH} was not changed."
    fi

    if is_dry; then
      log "DRY RUN: would push ${BRANCH} at $(git rev-parse --short "$merged")"
    else
      push_or_stop "push failed" "pushing ${BRANCH} after merging ${v} failed" origin "${merged}:refs/heads/${BRANCH}"
    fi
  fi

  if is_dry; then
    log "DRY RUN: would create the tag ${tag} and build its image"
    DONE_LINES+=("| ${v} | dry run | merged and verified, nothing pushed |")
    return 0
  fi

  if git ls-remote --exit-code --tags --refs origin "refs/tags/${tag}" > /dev/null 2>&1; then
    log "tag ${tag} already exists"
  else
    target="$(first_commit_containing "$v")"
    git tag -d "$tag" > /dev/null 2>&1 || true
    git tag -a "$tag" -m "asgard ${tag}: upstream ${v} + Vertex Claude (anthropic rawPredict) patch + GHCR workflow" "$target"
    push_or_stop "push failed" "pushing the tag ${tag} failed" origin "refs/tags/${tag}"
    log "pushed the tag ${tag} at ${target}"
  fi

  build_image "$tag"
  delete_merged_attempt_branch "$v"
  DONE_LINES+=("| ${v} | ${tag} | published |")
  CURRENT=""
}

main() {
  local current published newest versions top v count=0 followed=0 left
  local pending=()

  if [[ -n "$(git status --porcelain)" ]]; then
    stop "cannot start" "the work tree is not clean"
  fi
  current="$(git rev-parse --abbrev-ref HEAD)"
  if [[ "$current" != "$BRANCH" ]]; then
    stop "cannot start" "expected to be on ${BRANCH}, but on ${current}"
  fi
  if ! git config user.name > /dev/null; then
    git config user.name "github-actions[bot]"
    git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
  fi
  # No hook of this clone runs, whatever put it there.
  git config core.hooksPath /dev/null

  published="$(published_asgard_tags)" \
    || stop "cannot read GHCR" "cannot list the published images of ghcr.io/${GHCR_REPO}; is the package public?"
  newest="$(printf '%s\n' "$published" | sed -E 's/-asgard\.[0-9]+$//' | { grep -E "^${MAJOR}\." || true; } | sort -V | tail -n 1)"
  if [[ -z "$newest" ]]; then
    stop "cannot continue" "no published asgard image found on ghcr.io/${GHCR_REPO}, so there is nothing to continue from"
  fi

  # An upstream that cannot be read must not look like "no new release".
  versions="$(upstream_versions)" \
    || stop "cannot read upstream" "cannot list the release tags of ${UPSTREAM_URL}"
  if [[ -z "$versions" ]]; then
    stop "cannot read upstream" "${UPSTREAM_URL} has no ${MAJOR}.x.y release tags, which cannot be right"
  fi

  top="$(upstream_top_major)" || top=""
  if [[ -n "$top" ]] && version_gt "$top" "$MAJOR"; then
    log "::warning::upstream has a newer major version (${top}); this sync only follows ${MAJOR}"
    summary "Upstream has a newer major version (\`${top}\`). This sync only follows \`${MAJOR}\`."
  fi

  while IFS= read -r v; do
    [[ -n "$v" ]] || continue
    if version_gt "$v" "$newest"; then
      count=$((count + 1))
      if [[ $count -le $MAX_VERSIONS ]]; then
        pending+=("$v")
      fi
    fi
  done <<< "$versions"

  if [[ ${#pending[@]} -eq 0 ]]; then
    log "up to date: the newest published image is based on ${newest}"
    summary "Up to date: the newest published image is based on \`${newest}\`."
    close_issues
    return 0
  fi
  log "newest published image: ${newest}; to follow (${#pending[@]} of ${count}): ${pending[*]}"

  for v in "${pending[@]}"; do
    if [[ $followed -gt 0 && $(($(date +%s) - START_TS)) -ge $((TIME_BUDGET_MINUTES * 60)) ]]; then
      log "the time budget of ${TIME_BUDGET_MINUTES} minutes is used; the rest follows in the next run"
      break
    fi
    follow_version "$v"
    followed=$((followed + 1))
  done

  summary "### Followed upstream"
  summary ""
  summary "| upstream | tag | result |"
  summary "|---|---|---|"
  for line in "${DONE_LINES[@]}"; do
    summary "$line"
  done
  left=$((count - followed))
  if [[ $left -gt 0 ]]; then
    summary ""
    summary "${left} more version(s) are left for the next run."
  fi
  close_issues
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
