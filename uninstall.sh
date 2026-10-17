#!/usr/bin/env bash
# Entfernt das Helm-Release pool aus dem Kubernetes-Cluster, samt Secret pool-db.
# Der Namespace pool bleibt bestehen. MySQL-Container und Images in der
# Registry bleiben ebenfalls, dafür db-uninstall.sh.
#
# Wurde das Passwort rotiert oder der User gewechselt, passt ein neu angelegtes
# Secret (aus values.yaml) nicht mehr zur DB. Dann bricht das Skript ab, außer
# mit --force oder wenn die DB per db-uninstall.sh ohnehin neu aufgesetzt wird.
#
# Aufruf: ./uninstall.sh [--force]
set -euo pipefail

APP=pool
NAMESPACE=pool
SECRET=$APP-db

FORCE=false
[[ ${1:-} == --force ]] && FORCE=true

if ! helm status "$APP" -n "$NAMESPACE" >/dev/null 2>&1; then
  echo "Helm-Release $APP existiert nicht in Namespace $NAMESPACE, nichts zu tun."
  exit 0
fi

VERSION=$(kubectl get secret "$SECRET" -n "$NAMESPACE" \
  -o jsonpath='{.data.version}' 2>/dev/null | base64 -d || true)
if [[ -n $VERSION && $VERSION != initial ]] && ! $FORCE; then
  echo "Secret $SECRET enthält rotierte Zugangsdaten (Version $VERSION)." >&2
  echo "Ein neuer Install legt es mit den Startwerten aus values.yaml an, die die DB nicht mehr kennt." >&2
  echo "Zugangsdaten vorher sichern oder DB mit ./db-uninstall.sh neu aufsetzen, dann ./uninstall.sh --force." >&2
  exit 1
fi

echo "Entferne Helm-Release $APP ..."
helm uninstall "$APP" -n "$NAMESPACE" --wait >/dev/null

echo "Fertig. Namespace $NAMESPACE bleibt bestehen."
