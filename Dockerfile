# syntax=docker/dockerfile:1

# FGO game data API image.
# Requires the gamedata repo (e.g. fgo-game-data CN branch) to be mounted at
# /data/fgo-game-data-cn and a config file at /app/config.json (see config.docker.json).

FROM python:3.13-slim-bookworm

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    # psycopg needs libpq at runtime
    PYTHONPATH=/app

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

# Non-root user
RUN useradd --create-home --uid 1000 api \
    && mkdir -p /data /app/export \
    && chown -R api:api /app /data
USER api

# gamedata repo (CN branch) and config.json are mounted at runtime
VOLUME ["/data"]

EXPOSE 8000

# entrypoint script; strip CRLF in case the repo was checked out on Windows
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN sed -i 's/\r$//' /usr/local/bin/docker-entrypoint.sh \
    && chmod +x /usr/local/bin/docker-entrypoint.sh

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["gunicorn", "app.main:app", "-c", "gunicorn.conf.py"]
