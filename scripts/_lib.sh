set -eu
if [ "${IN_TOOLBOX:-}" != "1" ]; then
  cd "$(dirname "$0")/.."
  exec docker compose exec -T toolbox sh "/workspace/scripts/$(basename "$0")" "$@"
fi
cd /workspace
log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
