#!/usr/bin/env bash
# Poll an HTTP endpoint until it answers, so `make up` returns only when the stack is
# genuinely usable rather than merely "containers created".
set -uo pipefail

NAME="${1:?usage: wait-for.sh <name> <url> [timeout-seconds]}"
URL="${2:?usage: wait-for.sh <name> <url> [timeout-seconds]}"
TIMEOUT="${3:-120}"

printf '    %-18s' "$NAME"
deadline=$(( $(date +%s) + TIMEOUT ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  if curl -fsS --max-time 3 "$URL" >/dev/null 2>&1; then
    echo "ready"
    exit 0
  fi
  printf '.'
  sleep 2
done

echo " TIMEOUT after ${TIMEOUT}s ($URL)"
exit 1
