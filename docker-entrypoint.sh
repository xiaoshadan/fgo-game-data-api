#!/bin/sh
# Entrypoint for the FGO game data API container.
#
# 1. Waits for postgres and redis to be reachable.
# 2. Ensures the pgroonga extension exists (needed by fulltext indexes).
# 3. Clones the gamedata repo (CN branch) on first run.
# 4. With AUTO_UPDATE_ON_START=1: git-pulls gamedata and runs the data import
#    DIRECTLY (python) BEFORE starting gunicorn. This way the API port is
#    simply closed during the import instead of accepting requests that hang
#    or 404 while tables are being rebuilt.
# 5. Starts the API server (gunicorn).
#
# Runtime updates while the server is up still go through the webhook
# endpoint: POST /<github_webhook_secret>/update

set -e

CONFIG_FILE="${CONFIG_FILE:-/app/config.json}"
GAMEDATA_DIR="${GAMEDATA_DIR:-/data/fgo-game-data-cn}"
GAMEDATA_REPO="${GAMEDATA_REPO:-https://git.atlasacademy.io/atlasacademy/fgo-game-data.git}"
GAMEDATA_BRANCH="${GAMEDATA_BRANCH:-CN}"

log() {
    echo "[entrypoint] $(date '+%Y-%m-%d %H:%M:%S') $*"
}

# ---------------------------------------------------------------------------
# 1. Wait for dependencies
# ---------------------------------------------------------------------------
wait_for_postgres() {
    host="$1"
    log "Waiting for postgres ..."
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
    # The pgroonga extension must exist before any table with a
    # `USING pgroonga` index is created (app/db/load.py only creates it
    # much later, in load_script_list). POSTGRES_USER is a superuser so
    # this is allowed.
    log "Ensuring pgroonga extension exists ..."
    python -c "
import psycopg
with psycopg.connect('${POSTGRES_DSN}', autocommit=True) as conn:
    conn.execute('CREATE EXTENSION IF NOT EXISTS pgroonga;')
" || log "WARNING: failed to create pgroonga extension (may already exist or lack permissions)"
    log "pgroonga extension ready."
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
# 3. Run the data import BEFORE starting the server (AUTO_UPDATE_ON_START=1)
# ---------------------------------------------------------------------------
# The import is executed synchronously here, so gunicorn (and the API port)
# only comes up after the data is ready. No HTTP self-call, no event-loop
# blocking, no half-loaded tables answering 404.
if [ "${AUTO_UPDATE_ON_START:-0}" = "1" ]; then
    if [ -d "$GAMEDATA_DIR/.git" ]; then
        log "Pulling latest gamedata ..."
        git -C "$GAMEDATA_DIR" pull --ff-only || log "WARNING: git pull failed, using existing data"
    fi

    log "Starting data import (this can take several minutes) ..."
    python - "$CONFIG_FILE" <<'EOF'
import asyncio
import sys
import time

from app.config import Settings
from app.db.engine import async_engines
from app.redis import Redis
from app.tasks import load_and_export


async def main() -> None:
    settings = Settings()
    redis = Redis.from_url(str(settings.redisdsn))
    region_path = {region: data.gamedata for region, data in settings.data.items()}
    start = time.perf_counter()
    await load_and_export(redis, region_path, async_engines, False)
    print(f"[entrypoint] Import finished in {time.perf_counter() - start:.1f}s")
    try:
        await redis.aclose()
    except AttributeError:
        await redis.close()


asyncio.run(main())
EOF
    log "Data import done. Starting API server."
else
    log "AUTO_UPDATE_ON_START != 1, skipping import. Starting API server directly."
    log "NOTE: if the database is empty, all data endpoints will return 404."
fi

# ---------------------------------------------------------------------------
# 4. Start the server
# ---------------------------------------------------------------------------
exec "$@"
