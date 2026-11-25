# FGO game data API image.
# Requires the gamedata repo (e.g. fgo-game-data CN branch) to be mounted at
# /data/fgo-game-data-cn and a config file at /app/config.json (see config.docker.json).

# ---------------------------------------------------------------------------
# All download sources are pointed at China mirrors because docker.io /
# deb.debian.org / pypi.org may be blocked (403/timeout) in some networks.
# Override any of them at build time, e.g.:
#   docker compose build --build-arg BASE_IMAGE=docker.1ms.run/library/python:3.13-slim-bookworm api
# ---------------------------------------------------------------------------

# Base image: DaoCloud mirror of docker.io
ARG BASE_IMAGE=docker.m.daocloud.io/library/python:3.13-slim-bookworm
FROM ${BASE_IMAGE}

# Debian apt mirror: USTC mirror of deb.debian.org (bookworm)
ARG APT_MIRROR=mirrors.ustc.edu.cn
# PyPI index: Tsinghua TUNA mirror
ARG PIP_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_INDEX_URL=${PIP_INDEX_URL} \
    # psycopg needs libpq at runtime
    PYTHONPATH=/app

# Switch debian sources to the USTC mirror (handles both deb822 .sources
# format on bookworm and legacy sources.list)
RUN set -eux; \
    if [ -d /etc/apt/sources.list.d ]; then \
        sed -i "s|deb.debian.org|${APT_MIRROR}|g" /etc/apt/sources.list.d/debian.sources 2>/dev/null || true; \
    fi; \
    sed -i "s|deb.debian.org|${APT_MIRROR}|g" /etc/apt/sources.list 2>/dev/null || true

# git is required:
# - app/config.py get_repo_info() reads the api repo's git metadata (used by /info and openapi)
# - app/tasks.py update_data_repo() does `git pull` on the gamedata repo when the webhook is used
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        git \
        libpq5 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install dependencies first for better layer caching
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

# Copy the application code
COPY app ./app
COPY export ./export
COPY fgo_api_types ./fgo_api_types
COPY pyproject.toml ./

# The api repo itself must be a git repository for get_app_info() to work.
# The commit hash is baked into the image via build args.
ARG GIT_COMMIT=unknown
RUN git init -q \
    && git config user.email "docker@example.com" \
    && git config user.name "docker" \
    && git add -A \
    && git commit -qm "docker build ${GIT_COMMIT}" \
    && git tag -f build

# entrypoint script; strip CRLF in case the repo was checked out on Windows
# (must run as root: sed needs write access to /usr/local/bin)
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN sed -i 's/\r$//' /usr/local/bin/docker-entrypoint.sh \
    && chmod +x /usr/local/bin/docker-entrypoint.sh

# Non-root user
RUN useradd --create-home --uid 1000 api \
    && mkdir -p /data /app/export \
    && chown -R api:api /app /data
USER api

# gamedata repo (CN branch) and config.json are mounted at runtime
VOLUME ["/data"]

EXPOSE 8000

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["gunicorn", "app.main:app", "-c", "gunicorn.conf.py"]
