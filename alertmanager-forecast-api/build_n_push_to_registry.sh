#!/usr/bin/env bash
#set -euo pipefail

set +u 
# ==========================
# CONFIGURATION
# ==========================
REGISTRY="192.168.0.140:5000"
IMAGE_NAME="alertmanager-forecast-api"
VERSION_PREFIX="0.0"

DOCKERFILE_DEV="Dockerfile"
DOCKERFILE_PRD="Dockerfile"

# ==========================
# FUNCTIONS
# ==========================
log() {
  echo -e "\n🔹 $1"
}

error() {
  echo -e "\n❌ $1"
  exit 1
}

get_latest_version() {
  docker images --format "{{.Tag}}" "${REGISTRY}/${IMAGE_NAME}" \
    | grep "^${VERSION_PREFIX}\." \
    | sort -V \
    | tail -n 1
}

increment_version() {
  local last="$1"
  if [[ -z "$last" ]]; then
    echo "${VERSION_PREFIX}.1"
  else
    local patch
    patch=$(echo "$last" | awk -F. '{print $3}')
    echo "${VERSION_PREFIX}.$((patch + 1))"
  fi
}

# ==========================
# ENV SELECTION
# ==========================
echo "Select build environment:"
select ENV in dev prd; do
  case "$ENV" in
    dev)
      DOCKERFILE="$DOCKERFILE_DEV"
      TAG_SUFFIX="dev"
      break
      ;;
    prd)
      DOCKERFILE="$DOCKERFILE_PRD"
      TAG_SUFFIX="prd"
      break
      ;;
    *)
      echo "Invalid option"
      ;;
  esac
done

log "Selected environment: $ENV"
log "Using Dockerfile: $DOCKERFILE"

# ==========================
# VERSIONING
# ==========================
LAST_VERSION=$(get_latest_version || true)
NEW_VERSION=$(increment_version "$LAST_VERSION")

FULL_IMAGE="${REGISTRY}/${IMAGE_NAME}:${NEW_VERSION}-${TAG_SUFFIX}"
LATEST_IMAGE="${REGISTRY}/${IMAGE_NAME}:latest-${TAG_SUFFIX}"

log "Last version : ${LAST_VERSION:-none}"
log "New version  : $NEW_VERSION"

# ==========================
# BUILD
# ==========================
log "Building image..."
docker build \
  -f "$DOCKERFILE" \
  -t "$FULL_IMAGE" \
  -t "$LATEST_IMAGE" \
  .

# ==========================
# PUSH
# ==========================
log "Pushing image tags..."
docker push "$FULL_IMAGE"
docker push "$LATEST_IMAGE"

log "✅ Build & push complete"
echo "📦 Image pushed:"
echo "   - $FULL_IMAGE"
echo "   - $LATEST_IMAGE"
