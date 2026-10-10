#!/usr/bin/env sh
# k3d node containers sit outside the compose project, so compose down alone leaves them running.
set -eu
cd "$(dirname "$0")/.."
docker compose run --rm --no-deps cluster k3d cluster delete "${CLUSTER_NAME:-quote}" || true
docker compose down -v --remove-orphans
