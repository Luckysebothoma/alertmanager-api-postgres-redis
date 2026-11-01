#!/usr/bin/env bash
# build_push.sh — build, push and VERIFY the alertmanager-forecast-api image.
#
# Guarantees:
#   1. The image is built from the files currently in ./alertmanager-forecast-api
#      (never from the stale heredocs in deploy_alertmanager.sh).
#   2. The files inside the built image are hash-compared to the local files
#      BEFORE anything is pushed. A mismatch aborts.
#   3. The image is pushed under an immutable tag (git SHA) and :latest.
#   4. The registry is queried afterwards: both tags must resolve to the
#      digest that was just pushed.
#   5. With --deploy, the swarm service is pinned to that exact digest and the
#      running spec is verified.
#
# Usage:
#   ./build_push.sh                 build + verify + push
#   ./build_push.sh --deploy        ... then update the swarm service
#   ./build_push.sh --no-cache      ignore the docker layer cache
#   ./build_push.sh --strict        refuse to build with uncommitted changes
#
# Env overrides:
#   REGISTRY (192.168.0.140:5000)   IMAGE_REPO (alertmanager-forecast-api)
#   STACK_NAME (alertmanager-forecast-api)   SERVICE_NAME ($STACK_NAME_api)
#   APP_DIR   REGISTRY_SCHEME (http)   API_PORT (4400)   PULL_BASE (1)

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_NAME="${STACK_NAME:-alertmanager-forecast-api}"
APP_DIR="${APP_DIR:-$SCRIPT_DIR/alertmanager-forecast-api}"
REGISTRY="${REGISTRY:-192.168.0.140:5000}"
REGISTRY_SCHEME="${REGISTRY_SCHEME:-http}"
IMAGE_REPO="${IMAGE_REPO:-alertmanager-forecast-api}"
IMAGE_NAME="${REGISTRY}/${IMAGE_REPO}"
SERVICE_NAME="${SERVICE_NAME:-${STACK_NAME}_api}"
API_PORT="${API_PORT:-4400}"
PULL_BASE="${PULL_BASE:-1}"

DEPLOY=0; STRICT=0; NO_CACHE=0
for arg in "$@"; do
  case "$arg" in
    --deploy)   DEPLOY=1 ;;
    --strict)   STRICT=1 ;;
    --no-cache) NO_CACHE=1 ;;
    -h|--help)  sed -n '2,24p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown option: $arg (see --help)" >&2; exit 2 ;;
  esac
done

log()  { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >&2; }
die()  { log "ERROR: $*"; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }
trap 'die "unexpected failure at line $LINENO"' ERR

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
need docker; need sha256sum; need diff
[[ -d "$APP_DIR/src" ]]        || die "no src/ directory in $APP_DIR"
[[ -f "$APP_DIR/Dockerfile" ]] || die "no Dockerfile in $APP_DIR"
[[ -f "$APP_DIR/package.json" ]] || die "no package.json in $APP_DIR"
docker info >/dev/null 2>&1    || die "cannot talk to the docker daemon"

# ---------------------------------------------------------------------------
# Work out the tag. Dirty trees get a unique suffix so a tag never lies about
# which commit it contains.
# ---------------------------------------------------------------------------
STAMP="$(date -u +%Y%m%d%H%M%S)"
GIT_SHA="nogit"; DIRTY=0
if git -C "$APP_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  GIT_SHA="$(git -C "$APP_DIR" rev-parse --short=8 HEAD)"
  if [[ -n "$(git -C "$APP_DIR" status --porcelain -- "$APP_DIR")" ]]; then
    DIRTY=1
  fi
fi

if (( DIRTY )); then
  (( STRICT )) && die "uncommitted changes in $APP_DIR (--strict). Commit first."
  log "WARNING: uncommitted changes in $APP_DIR — tagging as dirty"
  TAG="${GIT_SHA}-dirty-${STAMP}"
elif [[ "$GIT_SHA" == "nogit" ]]; then
  TAG="${STAMP}"
else
  TAG="${GIT_SHA}"
fi

UNIQUE_REF="${IMAGE_NAME}:${TAG}"
LATEST_REF="${IMAGE_NAME}:latest"
log "image: $UNIQUE_REF (+ latest)"

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------
build_args=(build -t "$UNIQUE_REF" -t "$LATEST_REF"
  --label "org.opencontainers.image.revision=${GIT_SHA}"
  --label "org.opencontainers.image.created=$(date -u +%FT%TZ)"
  --label "org.opencontainers.image.version=${TAG}")
[[ "$PULL_BASE" == "1" ]] && build_args+=(--pull)
(( NO_CACHE )) && build_args+=(--no-cache)
build_args+=("$APP_DIR")

log "building..."
docker "${build_args[@]}"

# ---------------------------------------------------------------------------
# Verify image contents == local files (before pushing anything)
# ---------------------------------------------------------------------------
log "verifying image contents against local files..."
local_sums="$(cd "$APP_DIR" && sha256sum package.json src/* | sort -k2)"
image_sums="$(docker run --rm --entrypoint sh "$UNIQUE_REF" \
  -c 'cd /app && sha256sum package.json src/* | sort -k2')"

if ! diff <(printf '%s\n' "$local_sums") <(printf '%s\n' "$image_sums"); then
  die "image contents differ from local files — NOT pushing (diff above: < local, > image)"
fi
log "contents match ($(printf '%s\n' "$local_sums" | wc -l) files checked)"

# ---------------------------------------------------------------------------
# Push both tags
# ---------------------------------------------------------------------------
log "pushing $UNIQUE_REF"
docker push "$UNIQUE_REF"
log "pushing $LATEST_REF"
docker push "$LATEST_REF"

# ---------------------------------------------------------------------------
# Resolve the pushed digest and confirm the REGISTRY agrees
# ---------------------------------------------------------------------------
DIGEST="$(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$UNIQUE_REF" \
  | grep "^${IMAGE_NAME}@" | head -n1 | cut -d@ -f2 || true)"
[[ "$DIGEST" == sha256:* ]] || die "could not determine pushed digest"
log "pushed digest: $DIGEST"

registry_digest() { # tag -> digest as the registry reports it
  curl -fsSI \
    -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
    -H 'Accept: application/vnd.docker.distribution.manifest.list.v2+json' \
    -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
    -H 'Accept: application/vnd.oci.image.index.v1+json' \
    "${REGISTRY_SCHEME}://${REGISTRY}/v2/${IMAGE_REPO}/manifests/$1" \
    | tr -d '\r' | awk -F': ' 'tolower($1)=="docker-content-digest"{print $2}'
}

if command -v curl >/dev/null 2>&1; then
  for t in "$TAG" latest; do
    reg="$(registry_digest "$t" || true)"
    [[ -n "$reg" ]] || die "registry returned no digest for tag '$t'"
    [[ "$reg" == "$DIGEST" ]] || die "registry tag '$t' = $reg, expected $DIGEST"
    log "registry OK: ${IMAGE_REPO}:${t} -> ${reg}"
  done
else
  log "WARNING: curl not found, skipping registry verification"
fi

# ---------------------------------------------------------------------------
# Optional: deploy pinned to the exact digest
# ---------------------------------------------------------------------------
if (( DEPLOY )); then
  docker service inspect "$SERVICE_NAME" >/dev/null 2>&1 \
    || die "service '$SERVICE_NAME' not found (is the stack deployed?)"

  log "updating service $SERVICE_NAME -> ${UNIQUE_REF}@${DIGEST}"
  docker service update --detach=false --force --with-registry-auth \
    --image "${UNIQUE_REF}@${DIGEST}" "$SERVICE_NAME"

  spec_image="$(docker service inspect --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}' "$SERVICE_NAME")"
  [[ "$spec_image" == *"$DIGEST"* ]] || die "service spec image is '$spec_image', expected digest $DIGEST"
  log "service spec pinned to $DIGEST"

  log "current tasks:"
  docker service ps --filter desired-state=running "$SERVICE_NAME" \
    --format '  {{.Name}}  {{.Image}}  {{.CurrentState}}'

  if command -v curl >/dev/null 2>&1; then
    ok=0
    for _ in 1 2 3 4 5 6; do
      if curl -fsS "http://localhost:${API_PORT}/health" >/dev/null 2>&1; then ok=1; break; fi
      sleep 5
    done
    (( ok )) && log "health check OK on :${API_PORT}" \
             || log "WARNING: /health did not return 200 within 30s"
  fi

  log "recent service logs:"
  docker service logs --tail 5 "$SERVICE_NAME" 2>&1 | sed 's/^/  /' || true
fi

log "DONE  tag=${TAG}  digest=${DIGEST}"
(( DEPLOY )) || log "not deployed. To roll out: $0 --deploy"
