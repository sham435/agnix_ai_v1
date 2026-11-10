#!/bin/zsh
# Public (beta) stack control for the shams ai Dockerized backend.
# Always publishes host-loopback only; never touches the dev compose stack.
set -euo pipefail

COMPOSE_ARGS=(
  -f /Users/sham4/bonsai227b-shamsai/shamsai/shams/deploy/compose.public.yml
  --env-file "$HOME/.config/shams/public.env"
)

cmd="${1:-status}"
case "$cmd" in
  up|start)      exec docker compose "${COMPOSE_ARGS[@]}" up -d --build ;;
  build)         exec docker compose "${COMPOSE_ARGS[@]}" build ;;
  stop|down)     exec docker compose "${COMPOSE_ARGS[@]}" down ;;
  restart)       docker compose "${COMPOSE_ARGS[@]}" down && exec docker compose "${COMPOSE_ARGS[@]}" up -d ;;
  status|ps)     exec docker compose "${COMPOSE_ARGS[@]}" ps ;;
  logs)          exec docker compose "${COMPOSE_ARGS[@]}" logs -f --tail=100 "${2:-}" ;;
  config)        exec docker compose "${COMPOSE_ARGS[@]}" config ;;
  validate)      exec docker compose "${COMPOSE_ARGS[@]}" config -q ;;
  *)             exec docker compose "${COMPOSE_ARGS[@]}" logs --tail=50 ;;
esac
