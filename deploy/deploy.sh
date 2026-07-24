#!/usr/bin/env bash
#
# Pull-based deployment for CapitalView.
#
# Run periodically by the systemd timer (capitalview-deploy.timer).
# Idempotent: does nothing if neither the config nor the images changed.
#
#   git pull infra -> sops decrypt -> compose pull -> compose up -d -> prune
#
set -euo pipefail

# Infra repo root = parent directory of this script.
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

COMPOSE_FILE="docker-compose.prod.yaml"
ENC_FILE=".env.prod.enc"
ENV_FILE=".env"
SOPS_IMAGE="ghcr.io/getsops/sops:v3.11.0-alpine"
# age private key file used by SOPS (set by the systemd unit).
SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }

log "Syncing infra config (git)..."
git fetch --quiet origin
local_rev="$(git rev-parse @)"
remote_rev="$(git rev-parse '@{u}')"
if [ "$local_rev" != "$remote_rev" ]; then
  log "Config changed (${local_rev:0:7} -> ${remote_rev:0:7}), pulling."
  git pull --ff-only --quiet
else
  log "Config already up to date."
fi

log "Decrypting secrets (SOPS)..."
if [ -f "$ENC_FILE" ]; then
  if [ -f "$ENV_FILE" ] && [ "$ENV_FILE" -nt "$ENC_FILE" ]; then
    log "Secrets up to date ($ENV_FILE is newer than $ENC_FILE). Skipping SOPS."
  else
    log "Decrypting $ENC_FILE..."
    docker run --rm \
      -e SOPS_AGE_KEY="$(cat "$SOPS_AGE_KEY_FILE")" \
      -v "$REPO_DIR:/work" -w /work \
      "$SOPS_IMAGE" \
      --decrypt --input-type dotenv --output-type dotenv "$ENC_FILE" > "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    log "  -> $ENV_FILE"
  fi
fi

log "Pulling images..."
if ! docker compose -f "$COMPOSE_FILE" pull; then
  log "WARNING: 'compose pull' failed. Cleaning up stale images and retrying..."
  docker image prune -f || true
  docker compose -f "$COMPOSE_FILE" pull
fi

log "Applying compose (recreates only changed services)..."
if ! docker compose -f "$COMPOSE_FILE" up -d --remove-orphans 2>&1; then
  log "WARNING: 'compose up' failed (stale network or config change?). Tearing down and retrying..."
  docker compose -f "$COMPOSE_FILE" down --remove-orphans || true
  docker network prune -f || true
  log "Retrying compose up after clean teardown..."
  docker compose -f "$COMPOSE_FILE" up -d --remove-orphans
fi

log "Pruning dangling images..."
docker image prune -f

log "Deployment done."
