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
REPO_SLUG="${GITHUB_REPOSITORY:-asgard-ai-platform/CLIProxyAPI}"
GHCR_REPO="$(printf '%s' "$REPO_SLUG" | tr '[:upper:]' '[:lower:]')"
ISSUE_LABEL="asgard-sync"

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

image_exists() {
  local token code
  token="$(ghcr_token)" || return 1
  code="$(curl -s -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer ${token}" \
    -H 'Accept: application/vnd.oci.image.index.v1+json' \
    "https://ghcr.io/v2/${GHCR_REPO}/manifests/$1")" || return 1
  [[ "$code" == "200" ]]
}

# Prints "<id> <status> <conclusion>" of the newest asgard-image run on the tag, or nothing.
latest_run() {
  gh run list --repo "$REPO_SLUG" --workflow asgard-image.yml --branch "$1" --limit 1 \
    --json databaseId,status,conclusion \
    --jq '.[0] | select(. != null) | "\(.databaseId) \(.status) \(.conclusion)"'
}

dispatch_build() {
  gh workflow run asgard-image.yml --repo "$REPO_SLUG" --ref "$1" > /dev/null
}

# The gate runs upstream code (go test), so it gets no token and cannot write to the repository.
run_gate() {
  env -u GH_TOKEN -u GITHUB_TOKEN -u ASGARD_GIT_AUTH -u GITHUB_OUTPUT \
    bash .github/scripts/asgard-gate.sh
}

git_push() {
  if [[ -n "${ASGARD_GIT_AUTH:-}" ]]; then
    git -c "$ASGARD_GIT_AUTH" -c push.followTags=false push "$@"
  else
    git -c push.followTags=false push "$@"
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

# close_issues: the run got through, so whatever stopped the earlier runs is gone.
close_issues() {
  local n
  if is_dry; then
    return 0
  fi
  for n in $(gh issue list --repo "$REPO_SLUG" --label "$ISSUE_LABEL" --state open \
    --json number --jq '.[].number' 2> /dev/null); do
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

# build_image TAG: dispatch the image build for the tag (or join the run that is already
# going) and wait until it has published the image.
build_image() {
  local tag="$1" line id status conclusion prev_id="" tries=0 deadline
  CURRENT="${CURRENT:-$tag}"

  if image_exists "$tag"; then
    log "image $tag is already published"
    return 0
  fi

  line="$(latest_run "$tag")" || line=""
  id=""; status=""; conclusion=""
  read -r id status conclusion <<< "$line" || true

  if [[ -n "$id" && "$status" != "completed" ]]; then
    log "the image build for $tag is already running (run $id)"
  else
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
    stop "image build failed" "the image build for $tag finished with '${conclusion}' (run $id); fix the cause, then the next run retries it"
  fi
  image_exists "$tag" || stop "image missing after build" "the image build for $tag succeeded but the image is not on GHCR"
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

# follow_version V: bring main, the tag and the image up to upstream release V.
follow_version() {
  local v="$1" tag="$1-asgard.1" before changed conflicts target
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

    changed="$(git diff --name-status "$before" HEAD -- .github/workflows | tr '\n' ' ')"
    if [[ -n "$changed" ]]; then
      git reset --hard -q "$before"
      stop "upstream changes workflows" "upstream ${v} changes .github/workflows (${changed}). A new upstream workflow would become active in this fork, and the built-in token cannot push workflow files, so merge ${v} by hand and review the workflows first (see ASGARD.md)."
    fi

    if ! run_gate; then
      git reset --hard -q HEAD
      git clean -fdq
      push_attempt_branch "$v" "verification failed, needs fixes"
      git reset --hard -q "$before"
      git clean -fdq
      stop "verification failed" "the verification of the merge with upstream ${v} failed; see the log of this run.${ATTEMPT_BRANCH:+ The merge is on the branch ${ATTEMPT_BRANCH}.} ${BRANCH} was not changed."
    fi
    git reset --hard -q HEAD
    git clean -fdq

    if is_dry; then
      log "DRY RUN: would push ${BRANCH} at $(git rev-parse --short HEAD)"
    else
      git_push origin "HEAD:refs/heads/${BRANCH}" || stop "push failed" "pushing ${BRANCH} after merging ${v} failed"
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
    target="$(git log --first-parent --merges --format=%H -n 1 --grep="^Merge upstream ${v}\$" HEAD)"
    if [[ -z "$target" ]]; then
      target="$(git rev-parse HEAD)"
      log "no merge commit for ${v} found; tagging ${BRANCH} at ${target}"
    fi
    git tag -d "$tag" > /dev/null 2>&1 || true
    git tag -a "$tag" -m "asgard ${tag}: upstream ${v} + Vertex Claude (anthropic rawPredict) patch + GHCR workflow" "$target"
    git_push origin "refs/tags/${tag}" || stop "push failed" "pushing the tag ${tag} failed"
    log "pushed the tag ${tag} at ${target}"
  fi

  build_image "$tag"
  delete_merged_attempt_branch "$v"
  DONE_LINES+=("| ${v} | ${tag} | published |")
  CURRENT=""
}

main() {
  local current published newest v count=0
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

  published="$(published_asgard_tags)" \
    || stop "cannot read GHCR" "cannot list the published images of ghcr.io/${GHCR_REPO}; is the package public?"
  newest="$(printf '%s\n' "$published" | sed -E 's/-asgard\.[0-9]+$//' | { grep -E "^${MAJOR}\." || true; } | sort -V | tail -n 1)"
  if [[ -z "$newest" ]]; then
    stop "cannot continue" "no published asgard image found on ghcr.io/${GHCR_REPO}, so there is nothing to continue from"
  fi

  while IFS= read -r v; do
    [[ -n "$v" ]] || continue
    if version_gt "$v" "$newest"; then
      count=$((count + 1))
      if [[ $count -le $MAX_VERSIONS ]]; then
        pending+=("$v")
      fi
    fi
  done < <(upstream_versions)

  if [[ ${#pending[@]} -eq 0 ]]; then
    log "up to date: the newest published image is based on ${newest}"
    summary "Up to date: the newest published image is based on \`${newest}\`."
    close_issues
    return 0
  fi
  log "newest published image: ${newest}; to follow (${#pending[@]} of ${count}): ${pending[*]}"

  for v in "${pending[@]}"; do
    follow_version "$v"
  done

  summary "### Followed upstream"
  summary ""
  summary "| upstream | tag | result |"
  summary "|---|---|---|"
  for line in "${DONE_LINES[@]}"; do
    summary "$line"
  done
  if [[ $count -gt $MAX_VERSIONS ]]; then
    summary ""
    summary "$((count - MAX_VERSIONS)) more version(s) are left for the next run."
  fi
  close_issues
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
