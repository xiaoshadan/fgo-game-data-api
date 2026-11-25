#!/bin/sh
# Entrypoint for the FGO game data API container.
# 1. Waits for postgres and redis to be reachable.
# 2. Clones the gamedata repo (CN branch) on first run.
# 3. Starts the API server; the first data import is triggered via the
#    update endpoint (or automatically with AUTO_UPDATE_ON_START=1).

set -e

CONFIG_FILE="${CONFIG_FILE:-/app/config.json}"
GAMEDATA_DIR="${GAMEDATA_DIR:-/data/fgo-game-data-cn}"
GAMEDATA_REPO="${GAMEDATA_REPO:-https://git.atlasacademy.io/atlasacademy/fgo-game-data.git}"
GAMEDATA_BRANCH="${GAMEDATA_BRANCH:-CN}"

log() {
    echo "[entrypoint] $*"
}

# ---------------------------------------------------------------------------
# 1. Wait for dependencies
# ---------------------------------------------------------------------------
wait_for_postgres() {
    host="$1"
    log "Waiting for postgres at ${host} ..."
    until python -c "
import sys
import psycopg
try:
    with psycopg.connect('${host}', connect_timeout=3):
        sys.exit(0)
except Exception:
    sys.exit(1)
" 2>/dev/null; do
        sleep 2
    done
    log "Postgres is up."
}

wait_for_redis() {
    url="$1"
    log "Waiting for redis ..."
    until python -c "
import sys
from redis import Redis
try:
    Redis.from_url('${url}').ping()
except Exception:
    sys.exit(1)
sys.exit(0)
" 2>/dev/null; do
        sleep 2
    done
    log "Redis is up."
}

# Extract DSNs from config.json with python (no jq in slim image)
POSTGRES_DSN=$(python - "$CONFIG_FILE" <<'EOF'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fp:
    config = json.load(fp)
regions = config.get("data", {})
for region in regions.values():
    print(region["postgresdsn"])
    break
EOF
)

REDIS_DSN=$(python - "$CONFIG_FILE" <<'EOF'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fp:
    config = json.load(fp)
print(config.get("redisdsn", ""))
EOF
)

if [ -n "$POSTGRES_DSN" ]; then
    wait_for_postgres "$POSTGRES_DSN"
fi
if [ -n "$REDIS_DSN" ]; then
    wait_for_redis "$REDIS_DSN"
fi

# ---------------------------------------------------------------------------
# 2. Clone gamedata on first run
# ---------------------------------------------------------------------------
if [ ! -d "$GAMEDATA_DIR/master" ]; then
    log "Cloning gamedata (${GAMEDATA_BRANCH}) into ${GAMEDATA_DIR} ..."
    mkdir -p "$(dirname "$GAMEDATA_DIR")"
    git clone --depth 1 --branch "$GAMEDATA_BRANCH" "$GAMEDATA_REPO" "$GAMEDATA_DIR"
    log "Gamedata cloned."
else
    log "Gamedata already present at ${GAMEDATA_DIR}."
fi

# ---------------------------------------------------------------------------
# 3. Start the server
# ---------------------------------------------------------------------------
# AUTO_UPDATE_ON_START=1 triggers a data import right after boot by calling
# the webhook update endpoint locally. Requires GITHUB_WEBHOOK_SECRET to be
# set in config.json.
if [ "${AUTO_UPDATE_ON_START:-0}" = "1" ]; then
    (
        # Wait for the API to accept connections, then trigger the import
        sleep 10
        secret=$(python - "$CONFIG_FILE" <<'EOF'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fp:
    config = json.load(fp)
print(config.get("github_webhook_secret", ""))
EOF
)
        if [ -n "$secret" ]; then
            log "Triggering initial data import ..."
            python - <<EOF
import httpx

try:
    resp = httpx.post(
        "http://127.0.0.1:${PORT:-8000}/${secret}/update",
        json={"ref": "refs/heads/CN"},
        timeout=30,
    )
    print(f"[entrypoint] update endpoint responded {resp.status_code}")
except Exception as exc:
    print(f"[entrypoint] failed to trigger update: {exc}")
EOF
        else
            log "AUTO_UPDATE_ON_START=1 but github_webhook_secret is empty; skipping."
        fi
    ) &
fi

log "Starting API server ..."
exec "$@"
