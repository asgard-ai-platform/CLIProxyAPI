#!/usr/bin/env bash
# Offline tests for asgard-sync.sh: fake upstream and origin (fork) repositories, and stubs for
# the verification gate, GHCR and the GitHub CLI.
# Run it with: bash .github/scripts/asgard-sync.test.sh
# It creates temporary directories under $TMPDIR (default /tmp) and leaves them in place.
set -uo pipefail

SYNC="$(cd "$(dirname "$0")" && pwd)/asgard-sync.sh"
PASS=0
FAIL=0

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

check() { # description, command...
  local desc="$1"; shift
  if "$@" > /dev/null 2>&1; then
    PASS=$((PASS + 1)); printf 'ok    %s\n' "$desc"
  else
    FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$desc"
  fi
}
not() { ! "$@"; }
equals() { [ "$1" = "$2" ]; }
out_has() { printf '%s' "$OUT" | grep -q -- "$1"; }

# ---- fake world: upstream, origin (the fork) and a work clone ----------------------------------

new_world() {
  W="$(mktemp -d "${TMPDIR:-/tmp}/asgard-sync-test.XXXXXX")"
  git init -q --bare "$W/upstream.git"
  git init -q --bare "$W/origin.git"
  git init -q -b main "$W/seed"
  (
    cd "$W/seed" || exit 1
    printf 'a\n' > shared.txt
    printf 'base\n' > up.txt
    git add -A && git commit -q -m "upstream v8.0.74" && git tag v8.0.74
    git push -q "$W/upstream.git" HEAD:refs/heads/main refs/tags/v8.0.74
    git push -q "$W/origin.git" HEAD:refs/heads/main
  )
  git clone -q "$W/origin.git" "$W/patched"
  (
    cd "$W/patched" || exit 1
    printf 'fork\n' > shared.txt
    printf 'patch\n' > patch.txt
    git add -A && git commit -q -m "fork patch"
    git push -q origin HEAD:refs/heads/main
  )
  git clone -q "$W/origin.git" "$W/work"
  printf 'v8.0.74-asgard.1\n' > "$W/published.txt"
  : > "$W/builds.log"; : > "$W/gate.log"; : > "$W/build_fail.txt"
  cat > "$W/hooks.sh" <<EOF
published_asgard_tags() { cat "$W/published.txt"; }
image_exists() { grep -qx "\$1" "$W/published.txt"; }
run_gate() { if [ -e GATE_FAIL ]; then echo "gate failed" >&2; return 1; fi; echo gate >> "$W/gate.log"; }
build_image() {
  echo "\$1" >> "$W/builds.log"
  if grep -qx "\$1" "$W/build_fail.txt"; then die "build of \$1 failed"; fi
  echo "\$1" >> "$W/published.txt"
}
EOF
}

up_release() { # version [shell snippet run in the seed repo before committing]
  local v="$1"; shift
  (
    cd "$W/seed" || exit 1
    echo "$v" >> up.txt
    if [ $# -gt 0 ]; then eval "$1"; fi
    git add -A && git commit -q -m "upstream $v" && git tag "$v"
    git push -q "$W/upstream.git" HEAD:refs/heads/main "refs/tags/$v"
  )
}

# run_sync [VAR=value ...]: run the script in the work clone; sets OUT and RC.
run_sync() {
  OUT="$(cd "$W/work" && env ASGARD_ALLOW_LOCAL=1 ASGARD_UPSTREAM_URL="$W/upstream.git" \
    ASGARD_HOOKS="$W/hooks.sh" ASGARD_POLL_SECONDS=0 "$@" bash "$SYNC" 2>&1)"
  RC=$?
}

o() { git -C "$W/origin.git" "$@"; }
origin_main() { o rev-parse main; }
origin_has_tag() { o rev-parse -q --verify "refs/tags/$1^{commit}"; }
origin_tag_commit() { o rev-parse "refs/tags/$1^{commit}"; }
origin_contains() { o merge-base --is-ancestor "$(git -C "$W/upstream.git" rev-parse "$1^{commit}")" main; }
merge_commit_of() { o log --first-parent --merges --format=%H -n 1 --grep="^Merge upstream $1\$" main; }
merge_order() { o log --first-parent --merges --reverse --format=%s main | tr '\n' ',' ; }
merge_count() { o log --first-parent --merges --format=%H main | wc -l | tr -d ' '; }
builds() { tr '\n' ' ' < "$W/builds.log" | sed 's/ $//'; }
gate_runs() { wc -l < "$W/gate.log" | tr -d ' '; }
tree_clean() { [ -z "$(git -C "$W/work" status --porcelain)" ] && [ ! -e "$W/work/.git/MERGE_HEAD" ]; }

# ---- sync scenarios --------------------------------------------------------------------------

echo "# two versions released between two runs: both are followed, in order"
new_world; up_release v8.0.75; up_release v8.0.76
run_sync
check "exits 0" equals "$RC" 0
check "main contains v8.0.75" origin_contains v8.0.75
check "main contains v8.0.76" origin_contains v8.0.76
check "tag v8.0.75-asgard.1 exists" origin_has_tag v8.0.75-asgard.1
check "tag v8.0.76-asgard.1 exists" origin_has_tag v8.0.76-asgard.1
check "tag v8.0.75-asgard.1 points at the merge of v8.0.75" equals "$(origin_tag_commit v8.0.75-asgard.1)" "$(merge_commit_of v8.0.75)"
check "tag v8.0.76-asgard.1 points at the merge of v8.0.76" equals "$(origin_tag_commit v8.0.76-asgard.1)" "$(merge_commit_of v8.0.76)"
check "v8.0.75 is merged before v8.0.76" equals "$(merge_order)" "Merge upstream v8.0.75,Merge upstream v8.0.76,"
check "the images are built in order" equals "$(builds)" "v8.0.75-asgard.1 v8.0.76-asgard.1"
check "the gate ran once per version" equals "$(gate_runs)" 2
check "the work tree is clean" tree_clean
check "the fork patch is still in main" equals "$(o show main:patch.txt)" patch

echo "# nothing new"
new_world; up_release v8.0.75; printf 'v8.0.75-asgard.1\n' >> "$W/published.txt"
before="$(origin_main)"
run_sync
check "exits 0" equals "$RC" 0
check "main is unchanged" equals "$(origin_main)" "$before"
check "nothing is built" equals "$(builds)" ""

echo "# resume: v8.0.75 is merged and tagged but its image is missing"
new_world; up_release v8.0.75; up_release v8.0.76
run_sync ASGARD_MAX_VERSIONS=1
check "the first run follows v8.0.75 only" equals "$(builds)" "v8.0.75-asgard.1"
sed -i.bak '/v8.0.75-asgard.1/d' "$W/published.txt"   # pretend that the image is gone
: > "$W/builds.log"
merges_before="$(merge_count)"
tag_object_before="$(o rev-parse refs/tags/v8.0.75-asgard.1)"
sleep 1   # a recreated tag would get a different timestamp, and so a different object
run_sync
check "exits 0" equals "$RC" 0
check "v8.0.75 is built again, then v8.0.76" equals "$(builds)" "v8.0.75-asgard.1 v8.0.76-asgard.1"
check "v8.0.75 is not merged a second time" equals "$(merge_count)" "$((merges_before + 1))"
check "the gate is not run again for v8.0.75" equals "$(gate_runs)" 2
check "the existing tag v8.0.75-asgard.1 is left alone" equals "$(o rev-parse refs/tags/v8.0.75-asgard.1)" "$tag_object_before"

echo "# main is ahead: v8.0.75 and v8.0.76 were merged by hand, the tags are still missing"
new_world; up_release v8.0.75; up_release v8.0.76
(
  cd "$W/patched" || exit 1
  git fetch -q "$W/upstream.git" "+refs/tags/v8.0.75:refs/tags/v8.0.75" "+refs/tags/v8.0.76:refs/tags/v8.0.76"
  git merge -q --no-ff -m "Merge upstream v8.0.75" v8.0.75 && git merge -q --no-ff -m "Merge upstream v8.0.76" v8.0.76
  git push -q origin HEAD:refs/heads/main
)
git -C "$W/work" pull -q --ff-only
run_sync
check "exits 0" equals "$RC" 0
check "tag v8.0.75-asgard.1 points at the merge of v8.0.75, not at main" equals "$(origin_tag_commit v8.0.75-asgard.1)" "$(merge_commit_of v8.0.75)"
check "tag v8.0.76-asgard.1 points at the merge of v8.0.76" equals "$(origin_tag_commit v8.0.76-asgard.1)" "$(merge_commit_of v8.0.76)"
check "both images are built in order" equals "$(builds)" "v8.0.75-asgard.1 v8.0.76-asgard.1"
check "the gate is not run for merges that are already on main" equals "$(gate_runs)" 0

echo "# merge conflict in v8.0.76: v8.0.75 is done, v8.0.76 is left alone"
new_world; up_release v8.0.75; up_release v8.0.76 "echo up76 > shared.txt"
run_sync
check "exits non-zero" not equals "$RC" 0
check "names the conflicting file" out_has shared.txt
check "v8.0.75 is followed" origin_has_tag v8.0.75-asgard.1
check "there is no tag for v8.0.76" not origin_has_tag v8.0.76-asgard.1
check "main does not contain v8.0.76" not origin_contains v8.0.76
check "the work tree is clean and no merge is in progress" tree_clean

echo "# upstream v8.0.75 changes workflows: stop before anything is pushed"
new_world; up_release v8.0.75 "mkdir -p .github/workflows && echo x > .github/workflows/new.yml"; up_release v8.0.76
before="$(origin_main)"
run_sync
check "exits non-zero" not equals "$RC" 0
check "explains the workflow change" out_has '.github/workflows'
check "main is unchanged" equals "$(origin_main)" "$before"
check "nothing is built" equals "$(builds)" ""
check "the work tree is clean" tree_clean

echo "# the gate fails for v8.0.75: nothing is pushed and v8.0.76 is not attempted"
new_world; up_release v8.0.75 "echo x > GATE_FAIL"; up_release v8.0.76
before="$(origin_main)"
run_sync
check "exits non-zero" not equals "$RC" 0
check "main is unchanged" equals "$(origin_main)" "$before"
check "no tag for v8.0.75" not origin_has_tag v8.0.75-asgard.1
check "no tag for v8.0.76" not origin_has_tag v8.0.76-asgard.1
check "the work tree is clean" tree_clean

echo "# the image build fails for v8.0.75: v8.0.76 waits, the next run retries"
new_world; up_release v8.0.75; up_release v8.0.76
echo v8.0.75-asgard.1 > "$W/build_fail.txt"
run_sync
check "exits non-zero" not equals "$RC" 0
check "v8.0.75 is merged and tagged" origin_has_tag v8.0.75-asgard.1
check "v8.0.76 is not attempted" not origin_has_tag v8.0.76-asgard.1
: > "$W/build_fail.txt"; : > "$W/builds.log"
run_sync
check "the next run exits 0" equals "$RC" 0
check "the next run builds v8.0.75 and then v8.0.76" equals "$(builds)" "v8.0.75-asgard.1 v8.0.76-asgard.1"

echo "# dry run"
new_world; up_release v8.0.75; up_release v8.0.76
before="$(origin_main)"
run_sync ASGARD_DRY_RUN=true
check "exits 0" equals "$RC" 0
check "main is unchanged" equals "$(origin_main)" "$before"
check "no tag for v8.0.75" not origin_has_tag v8.0.75-asgard.1
check "no tag for v8.0.76" not origin_has_tag v8.0.76-asgard.1
check "nothing is built" equals "$(builds)" ""
check "both versions are verified" equals "$(gate_runs)" 2

echo "# versions are compared numerically: v8.0.99 before v8.0.100"
new_world; up_release v8.0.99; up_release v8.0.100
run_sync
check "exits 0" equals "$RC" 0
check "v8.0.99 then v8.0.100" equals "$(builds)" "v8.0.99-asgard.1 v8.0.100-asgard.1"
check "each has its own merge commit" equals "$(merge_order)" "Merge upstream v8.0.99,Merge upstream v8.0.100,"

echo "# the number of versions per run is capped, the rest follows in the next run"
new_world; up_release v8.0.75; up_release v8.0.76
run_sync ASGARD_MAX_VERSIONS=1
check "only v8.0.75 is followed" equals "$(builds)" "v8.0.75-asgard.1"
check "v8.0.76 is not touched yet" not origin_has_tag v8.0.76-asgard.1
run_sync
check "the next run follows v8.0.76" equals "$(builds)" "v8.0.75-asgard.1 v8.0.76-asgard.1"

echo "# other tag shapes are ignored"
new_world; up_release v8.0.75
(cd "$W/seed" && git tag v9.0.0 && git tag v8.0.77-rc1 && git tag v7.9.9 \
  && git push -q "$W/upstream.git" refs/tags/v9.0.0 refs/tags/v8.0.77-rc1 refs/tags/v7.9.9)
run_sync
check "exits 0" equals "$RC" 0
check "only v8.0.75 is followed" equals "$(builds)" "v8.0.75-asgard.1"

echo "# refuses to run outside GitHub Actions"
new_world
OUT="$(cd "$W/work" && env -u ASGARD_ALLOW_LOCAL GITHUB_ACTIONS= bash "$SYNC" 2>&1)"; RC=$?
check "exits with 2" equals "$RC" 2

# ---- build_image with a fake gh and a fake curl ----------------------------------------------

new_fakes() {
  new_world
  mkdir -p "$W/bin" "$W/gh"
  cat > "$W/bin/curl" <<'EOF'
#!/usr/bin/env bash
url="${*: -1}"
case "$url" in
  */token*) echo '{"token":"t"}' ;;
  */manifests/*) tag="${url##*/}"; if grep -qx "$tag" "$FAKE_PUBLISHED"; then echo 200; else echo 404; fi ;;
  */tags/list*) jq -R -s '{tags: (split("\n") | map(select(length > 0)))}' < "$FAKE_PUBLISHED" ;;
esac
EOF
  # "gh workflow run" and the "join" flag switch "gh run list" from before.txt to the states in
  # after.txt, one line per call (the last one repeats). A completed run publishes the image.
  cat > "$W/bin/gh" <<'EOF'
#!/usr/bin/env bash
if [ "$1 $2" = "workflow run" ]; then touch "$FAKE_GH/dispatched"; exit 0; fi
if [ "$1 $2" = "run list" ]; then
  tag=""; while [ $# -gt 0 ]; do [ "$1" = "--branch" ] && tag="$2"; shift; done
  if [ -e "$FAKE_GH/dispatched" ] || [ -e "$FAKE_GH/join" ]; then
    # "stale" holds a number of calls that still return the old list after the dispatch, like the real
    # API does for a moment before the new run shows up.
    s="$(cat "$FAKE_GH/stale" 2>/dev/null || echo 0)"
    if [ "$s" -gt 0 ]; then echo "$((s - 1))" > "$FAKE_GH/stale"; cat "$FAKE_GH/before.txt" 2>/dev/null; exit 0; fi
    n="$(cat "$FAKE_GH/idx" 2>/dev/null || echo 0)"; total="$(wc -l < "$FAKE_GH/after.txt" | tr -d ' ')"
    line="$(sed -n "$((n + 1))p" "$FAKE_GH/after.txt")"
    if [ "$((n + 1))" -lt "$total" ]; then echo "$((n + 1))" > "$FAKE_GH/idx"; fi
    case "$line" in *"completed success"*) echo "$tag" >> "$FAKE_PUBLISHED" ;; esac
    echo "$line"
  else
    cat "$FAKE_GH/before.txt" 2>/dev/null || true
  fi
fi
EOF
  chmod +x "$W/bin/curl" "$W/bin/gh"
}
run_build() { # tag; uses the fakes in $W
  (
    export PATH="$W/bin:$PATH" FAKE_PUBLISHED="$W/published.txt" FAKE_GH="$W/gh"
    export ASGARD_ALLOW_LOCAL=1 ASGARD_POLL_SECONDS=0 GITHUB_REPOSITORY=asgard-ai-platform/CLIProxyAPI
    export ASGARD_BUILD_TIMEOUT_MINUTES="${BUILD_TIMEOUT:-60}"
    # shellcheck disable=SC1090
    source "$SYNC"
    build_image "$1"
  ) > "$W/build.out" 2>&1
  RC=$?
}
dispatched() { [ -e "$W/gh/dispatched" ]; }

echo "# build_image: dispatch, join a running build, retry after a failed one"
new_fakes; printf 'v8.0.75-asgard.1\n' >> "$W/published.txt"
run_build v8.0.75-asgard.1
check "a published image is not built again: exits 0" equals "$RC" 0
check "a published image is not built again: no dispatch" not dispatched

new_fakes; printf '201 queued \n201 in_progress \n201 completed success\n' > "$W/gh/after.txt"
run_build v8.0.75-asgard.1
check "no run yet: exits 0 after the new run succeeds" equals "$RC" 0
check "no run yet: the build is dispatched" dispatched

new_fakes; printf '300 queued \n300 completed failure\n' > "$W/gh/after.txt"
run_build v8.0.75-asgard.1
check "a failed build stops the sync" not equals "$RC" 0
check "the failure names the conclusion" grep -q failure "$W/build.out"

new_fakes; touch "$W/gh/join"; printf '150 in_progress \n150 completed success\n' > "$W/gh/after.txt"
printf '150 in_progress \n' > "$W/gh/before.txt"
run_build v8.0.75-asgard.1
check "a running build is joined: exits 0" equals "$RC" 0
check "a running build is joined: nothing is dispatched" not dispatched

new_fakes; printf '100 completed failure\n' > "$W/gh/before.txt"; printf '101 queued \n101 completed success\n' > "$W/gh/after.txt"
run_build v8.0.75-asgard.1
check "after an old failed run: exits 0 once the new run succeeds" equals "$RC" 0
check "after an old failed run: the build is dispatched again" dispatched

new_fakes; printf '100 completed failure\n' > "$W/gh/before.txt"; printf '101 queued \n101 completed success\n' > "$W/gh/after.txt"
echo 3 > "$W/gh/stale"   # the new run only shows up on the 4th look
run_build v8.0.75-asgard.1
check "waits for the new run instead of taking the old failed one: exits 0" equals "$RC" 0
check "waits for the new run instead of taking the old failed one: dispatched" dispatched

new_fakes; printf '400 queued \n' > "$W/gh/after.txt"
BUILD_TIMEOUT=0 run_build v8.0.75-asgard.1
check "a build that never finishes times out" not equals "$RC" 0
check "the timeout is reported" grep -q 'did not finish' "$W/build.out"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
