#!/usr/bin/env bash
# Entfernt den MySQL-Container aus db.sh samt Daten-Volume.
#
# Aufruf: ./db-uninstall.sh [--keep-data]   (--keep-data: Volume behalten)
set -euo pipefail

CONTAINER_NAME=mysql-pool
VOLUME=mysql-pool-data

KEEP_DATA=false
[[ ${1:-} == --keep-data ]] && KEEP_DATA=true

# Stoppen und löschen, trennt ihn auch vom kind-Netzwerk
if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
  echo "Entferne Container $CONTAINER_NAME ..."
  docker rm -f "$CONTAINER_NAME" >/dev/null
else
  echo "Container $CONTAINER_NAME existiert nicht."
fi

if $KEEP_DATA; then
  echo "Volume $VOLUME bleibt erhalten."
elif docker volume inspect "$VOLUME" >/dev/null 2>&1; then
  echo "Entferne Volume $VOLUME ..."
  docker volume rm "$VOLUME" >/dev/null
else
  echo "Volume $VOLUME existiert nicht."
fi

echo "Fertig."
