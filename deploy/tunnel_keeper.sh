#!/usr/bin/env bash
# Public quick-tunnel keeper.
#
# A TryCloudflare quick tunnel is handed a new random hostname every time it
# starts, and Rails reads the live hostname out of APP_HOST for three separate
# decisions at boot — the host allowlist, the origins Action Cable accepts, and
# the host it puts in generated URLs. So "the demo link stopped working" has
# two causes: the tunnel process died, and the app no longer recognises the
# hostname it is now being addressed by.
#
# This script keeps both true: it supervises cloudflared against the loopback
# Apache origin, and whenever the hostname changes it rewrites APP_HOST and
# recreates the web + jobs containers (env is read at container creation, so a
# restart is unavoidable). The URL it last published goes in
# ~/.config/shams/tunnel_url so anyone can see what the demo address currently is.
#
# It also watches the published address itself, because Cloudflare can revoke a
# quick tunnel's route without killing the process — that leaves a healthy-
# looking cloudflared behind a hostname that no longer resolves.
#
# It does not make the URL stable — only a named tunnel on a domain you own
# does that. It makes the rotation stop needing a human.

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

REPO="/Users/sham4/bonsai227b-shamsai/shamsai/shams"
ENV_FILE="$HOME/.config/shams/public.env"
URL_FILE="$HOME/.config/shams/tunnel_url"
LOG="$REPO/log/tunnel_keeper.log"
TUNNEL_LOG="$REPO/log/tunnel_cloudflared.log"
COMPOSE_FILE="$REPO/deploy/compose.public.yml"
ORIGIN="http://127.0.0.1:80"

mkdir -p "$(dirname "$LOG")" "$(dirname "$ENV_FILE")"

say() { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }

child=""
cleanup() { [ -n "$child" ] && kill "$child" 2>/dev/null; }
trap cleanup EXIT INT TERM

# The address is only worth reporting once something is actually serving it.
verify() {
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$1/login" 2>/dev/null) || code="000"
  [ "$code" = "200" ] || [ "$code" = "302" ]
}

wait_for_public() {
  local _
  # Two minutes: the check is only a line in the log, but a container recreated
  # seconds ago spends most of that booting Puma, and reporting "not answering"
  # while it is still coming up would be a false alarm.
  for _ in $(seq 1 12); do
    verify "$1" && return 0
    sleep 10
  done
  return 1
}

# A public address that stopped answering is only the tunnel's fault when the
# loopback origin still answers. If Apache or Rails is down, restarting
# cloudflared would rotate the URL for nothing and make the outage worse.
origin_down() {
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
    -H "Host: $1" "$ORIGIN/login" 2>/dev/null) || code="000"
  [ "$code" = "000" ] || [ "$code" = "502" ] || [ "$code" = "503" ]
}

# Env is baked into the containers, so a hostname change means recreating them;
# a Docker Desktop that is still booting at login is the usual reason the first
# attempt fails, and giving up there would leave the demo down until the tunnel
# itself restarted.
publish() {
  local want="$1" attempt current
  for attempt in 1 2 3; do
    current=$(sed -n 's/^APP_HOST=//p' "$ENV_FILE" | head -1)
    if [ "$want" = "$current" ]; then
      say "APP_HOST already $want"
      return 0
    fi
    cp -p "$ENV_FILE" "$ENV_FILE.bak-tunnel-keeper" 2>/dev/null
    sed -i '' "s|^APP_HOST=.*|APP_HOST=$want|" "$ENV_FILE"
    say "APP_HOST $current -> $want, recreating web + jobs (attempt $attempt)"
    if (cd "$REPO/deploy" && docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d web jobs >>"$LOG" 2>&1); then
      return 0
    fi
    say "compose up failed; retrying in 20s"
    sleep 20
  done
  return 1
}

published=""
while :; do
  cloudflared tunnel --url "$ORIGIN" --no-autoupdate >"$TUNNEL_LOG" 2>&1 &
  child=$!

  url=""
  for _ in $(seq 1 60); do
    kill -0 "$child" 2>/dev/null || break
    url=$(grep -Eo 'https://[a-z0-9-]+\.trycloudflare\.com' "$TUNNEL_LOG" | head -1)
    [ -n "$url" ] && break
    sleep 1
  done

  if [ -z "$url" ]; then
    say "cloudflared gave no hostname; waiting before another try"
    wait "$child" 2>/dev/null
    child=""
    sleep 20
    continue
  fi

  host="${url#https://}"
  printf '%s\n' "$url" >"$URL_FILE"
  say "tunnel up at $url"

  # Only when the hostname actually moved is the app rebuilt around it; a
  # crash-loop of tunnels on the same address must not restart production each
  # time.
  if [ "$host" != "$published" ] && publish "$host"; then
    published="$host"
  fi

  if wait_for_public "$url"; then
    say "$url serving"
  else
    say "$url is not answering on /login"
  fi

  # A revoked quick-tunnel route does not kill cloudflared: it retries forever
  # behind a hostname that has already been un-registered, so the demo can be
  # fully dead while the process looks healthy. Waiting on the child alone would
  # miss that, so the address itself is polled and the child is cut loose once it
  # has clearly stopped answering while the origin is fine.
  dead_streak=0
  while :; do
    kill -0 "$child" 2>/dev/null || break
    if verify "$url"; then
      dead_streak=0
    elif origin_down "$host"; then
      say "$url not answering and the loopback origin is down; leaving the tunnel alone"
      dead_streak=0
    else
      dead_streak=$((dead_streak + 1))
      say "$url not answering ($dead_streak)"
      if [ "$dead_streak" -ge 3 ]; then
        say "restarting the tunnel; the hostname will change"
        kill "$child" 2>/dev/null
        break
      fi
    fi
    sleep 60
  done

  wait "$child" 2>/dev/null
  child=""
  say "cloudflared exited; starting another tunnel (this changes the URL)"
  sleep 5
done
