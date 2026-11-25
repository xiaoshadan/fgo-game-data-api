# Gunicorn configuration for the FGO game data API.
# The app loads game data into postgres/redis on the first request after start,
# so a single worker keeps memory usage predictable. Increase workers only if
# you have enough RAM (each worker loads its own caches).

import os

bind = f"0.0.0.0:{os.environ.get('PORT', '8000')}"
workers = int(os.environ.get("WEB_CONCURRENCY", "1"))
worker_class = "uvicorn.workers.UvicornWorker"
timeout = 300
graceful_timeout = 60
# Data import can take a long time; don't kill the worker while it runs
max_requests = 0
loglevel = os.environ.get("LOG_LEVEL", "info")
accesslog = "-"
errorlog = "-"
# Forward SIGTERM to workers so docker stop is fast
preload_app = False
