#!/usr/bin/env bash
# Entfernt den MySQL-Container aus db.sh samt Daten-Volume und dem
# Kubernetes-Secret mit den DB-Zugangsdaten.
#
# Läuft auf dem DB-Host selbst (DB_HOST aus db.env).
#
# Aufruf: ./db-uninstall.sh [--keep-data]   (--keep-data: Volume und Secret behalten)
set -euo pipefail

CONTAINER_NAME=mysql-pool
VOLUME=mysql-pool-data
NAMESPACE=pool
SECRET=pool-db

KEEP_DATA=false
[[ ${1:-} == --keep-data ]] && KEEP_DATA=true

# Stoppen und löschen
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

# Ohne Volume kennt eine neue DB nur noch die Startpasswörter. Das Secret mit
# rotierten Zugangsdaten passt dann nicht mehr. Löschen, damit install.sh es
# wieder aus values.yaml anlegt.
if ! $KEEP_DATA; then
  if kubectl delete secret "$SECRET" -n "$NAMESPACE" --ignore-not-found 2>/dev/null | grep -q deleted; then
    echo "Secret $SECRET entfernt, install.sh legt es neu an."
  elif ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    echo "Cluster oder Namespace $NAMESPACE nicht erreichbar, Secret $SECRET nicht geprüft." >&2
  else
    echo "Secret $SECRET existiert nicht."
  fi
fi

echo "Fertig."
