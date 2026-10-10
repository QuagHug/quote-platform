#!/usr/bin/env sh
# Full teardown: the k3d node containers are created through the Docker socket,
# so `docker compose down` alone would leave them running.
set -eu
cd "$(dirname "$0")/.."
docker compose run --rm --no-deps cluster k3d cluster delete "${CLUSTER_NAME:-quote}" || true
docker compose down -v --remove-orphans
