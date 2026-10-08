#!/usr/bin/env bash
# Liest einmal pro Sekunde die Nachrichten, parallel zu change-password.sh.
# Jeder fehlgeschlagene Request wird gemeldet, Ctrl+C zeigt die Bilanz.
#
# Aufruf: ./test.sh [url]
set -uo pipefail

URL=${1:-http://pool.localhost/api/messages}
ok=0
fail=0

trap 'echo; echo "Bilanz: $ok ok, $fail fehlgeschlagen"; exit $((fail > 0))' INT TERM

echo "Lese $URL jede Sekunde (Ctrl+C beendet)"
while true; do
  code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$URL")
  if [[ $code == 2* ]]; then
    ok=$((ok + 1))
    echo "$(date +%T) $code"
  else
    fail=$((fail + 1))
    echo "$(date +%T) $code FEHLER"
  fi
  sleep 1
done
