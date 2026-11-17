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

if [[ "${GITHUB_ACTIONS:-}" != "true" && "${ASGARD_ALLOW_LOCAL:-}" != "1" ]]; then
  echo "refusing to run outside GitHub Actions: this script resets the work tree" >&2
  exit 2
fi

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

# build_image TAG: dispatch the image build for the tag (or join the run that is already
# going) and wait until it has published the image.
build_image() {
  local tag="$1" line id status conclusion prev_id="" tries=0 deadline

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
    dispatch_build "$tag" || die "cannot start the image build for $tag"
    while :; do
      line="$(latest_run "$tag")" || line=""
      id=""; status=""; conclusion=""
      read -r id status conclusion <<< "$line" || true
      if [[ -n "$id" && "$id" != "$prev_id" ]]; then
        break
      fi
      tries=$((tries + 1))
      if [[ $tries -gt 20 ]]; then
        die "the image build for $tag did not start"
      fi
      sleep "$POLL_SECONDS"
    done
    log "started the image build for $tag (run $id)"
  fi

  deadline=$(( $(date +%s) + BUILD_TIMEOUT_MINUTES * 60 ))
  while [[ "$status" != "completed" ]]; do
    if [[ $(date +%s) -ge $deadline ]]; then
      die "the image build for $tag (run $id) did not finish within ${BUILD_TIMEOUT_MINUTES} minutes; the next run will pick it up"
    fi
    sleep "$POLL_SECONDS"
    line="$(latest_run "$tag")" || line=""
    id=""; status=""; conclusion=""
    read -r id status conclusion <<< "$line" || true
  done

  if [[ "$conclusion" != "success" ]]; then
    die "the image build for $tag finished with '${conclusion}' (run $id); fix the cause, then the next run retries it"
  fi
  image_exists "$tag" || die "the image build for $tag succeeded but the image is not on GHCR"
}

if [[ -n "${ASGARD_HOOKS:-}" ]]; then
  # shellcheck disable=SC1090
  source "$ASGARD_HOOKS"
fi

# ---- sync ----------------------------------------------------------------------------------

DONE_LINES=()

# follow_version V: bring main, the tag and the image up to upstream release V.
follow_version() {
  local v="$1" tag="$1-asgard.1" before changed conflicts target

  log "== following upstream $v"
  git fetch --no-tags -q "$UPSTREAM_URL" "+refs/tags/${v}:refs/tags/${v}" \
    || die "cannot fetch the upstream tag $v"

  if git merge-base --is-ancestor "refs/tags/${v}" HEAD; then
    log "$BRANCH already contains $v"
  else
    before="$(git rev-parse HEAD)"
    if ! git merge --no-ff -q -m "Merge upstream ${v}" "refs/tags/${v}" > /dev/null 2>&1; then
      conflicts="$(git diff --name-only --diff-filter=U | tr '\n' ' ')"
      git merge --abort > /dev/null 2>&1 || git reset --hard -q "$before"
      die "merging upstream ${v} into ${BRANCH} conflicts in: ${conflicts:-unknown files}. Merge it by hand as described in ASGARD.md; the next run continues from there."
    fi

    changed="$(git diff --name-status "$before" HEAD -- .github/workflows | tr '\n' ' ')"
    if [[ -n "$changed" ]]; then
      git reset --hard -q "$before"
      die "upstream ${v} changes .github/workflows (${changed}). A new upstream workflow would become active in this fork, and the built-in token cannot push workflow files, so merge ${v} by hand and review the workflows first (see ASGARD.md)."
    fi

    if ! run_gate; then
      git reset --hard -q "$before"
      git clean -fdq
      die "the verification of the merge with upstream ${v} failed; see the log of this run. ${BRANCH} was not changed."
    fi
    git reset --hard -q HEAD
    git clean -fdq

    if is_dry; then
      log "DRY RUN: would push ${BRANCH} at $(git rev-parse --short HEAD)"
    else
      git_push origin "HEAD:refs/heads/${BRANCH}" || die "pushing ${BRANCH} after merging ${v} failed"
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
    git_push origin "refs/tags/${tag}" || die "pushing the tag ${tag} failed"
    log "pushed the tag ${tag} at ${target}"
  fi

  build_image "$tag"
  DONE_LINES+=("| ${v} | ${tag} | published |")
}

main() {
  local current published newest v count=0
  local pending=()

  if [[ -n "$(git status --porcelain)" ]]; then
    die "the work tree is not clean"
  fi
  current="$(git rev-parse --abbrev-ref HEAD)"
  if [[ "$current" != "$BRANCH" ]]; then
    die "expected to be on ${BRANCH}, but on ${current}"
  fi
  if ! git config user.name > /dev/null; then
    git config user.name "github-actions[bot]"
    git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
  fi

  published="$(published_asgard_tags)" \
    || die "cannot list the published images of ghcr.io/${GHCR_REPO}; is the package public?"
  newest="$(printf '%s\n' "$published" | sed -E 's/-asgard\.[0-9]+$//' | { grep -E "^${MAJOR}\." || true; } | sort -V | tail -n 1)"
  if [[ -z "$newest" ]]; then
    die "no published asgard image found on ghcr.io/${GHCR_REPO}, so there is nothing to continue from"
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
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
