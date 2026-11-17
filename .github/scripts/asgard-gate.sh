#!/usr/bin/env bash
# Verification gate shared by asgard-sync.yml (before pushing a merge) and asgard-image.yml
# (before building an image).
#
# It pins one models catalog revision, refreshes the embedded catalogs from it, then builds,
# vets and tests the packages the Vertex Claude patch touches. The pinned revision is written
# as "ref=<sha>" to $GITHUB_OUTPUT when that is set.
#
# Note: refreshing the catalogs overwrites tracked files under internal/registry/models, so the
# caller has to restore the work tree afterwards.
set -euo pipefail

ref="$(git ls-remote https://github.com/router-for-me/models.git refs/heads/main | cut -f1)"
if [[ ! "$ref" =~ ^[0-9a-f]{40}$ ]]; then
  echo "failed to resolve the models catalog revision: '$ref'" >&2
  exit 1
fi
echo "models catalog revision: $ref"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "ref=$ref" >> "$GITHUB_OUTPUT"
fi

MODELS_REPOSITORY_REF="$ref" bash .github/scripts/refresh-model-catalogs.sh

go build -o test-output ./cmd/server
rm -f test-output

go vet ./internal/runtime/executor/ ./internal/config/ ./sdk/cliproxy/

go test -count=1 -run 'VertexClaude' ./internal/runtime/executor/ ./internal/config/ ./sdk/cliproxy/

# Known upstream test failures are skipped here and listed in ASGARD.md; re-check them on every sync.
go test -count=1 -skip 'TestServiceHeartbeatFailoverDoesNotDrainBlockingScope' \
  ./internal/runtime/executor/... ./internal/config/... ./internal/registry/... ./sdk/cliproxy/...
