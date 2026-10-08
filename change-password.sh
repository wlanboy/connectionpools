#!/usr/bin/env bash
# Rotiert das DB-Passwort ohne Downtime:
#  1. MySQL: neues Passwort setzen, altes bleibt gültig (Dual Password)
#  2. Kubernetes-Secret aktualisieren und Pods zum Volume-Sync anstoßen
#  3. Warten, bis jeder Pod seinen Hikari-Pool umgestellt hat
#  4. MySQL: altes Passwort verwerfen
# Bricht das Skript vor Schritt 4 ab, gelten beide Passwörter weiter.
# Nichts ist kaputt, das Skript kann einfach erneut laufen.
#
# Aufruf: ./change-password.sh [neues-passwort]   (ohne Argument: zufällig)
set -euo pipefail

APP=pool
NAMESPACE=pool
SECRET=$APP-db
DB_CONTAINER=mysql-pool
DB_USER=pool
ROOT_PASSWORD=rootsecret
TIMEOUT=180

NEW_PASSWORD=${1:-$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 24)}
VERSION=$(date +%Y%m%d%H%M%S)

mysql_root() {
  docker exec -i -e MYSQL_PWD="$ROOT_PASSWORD" "$DB_CONTAINER" mysql -h 127.0.0.1 -uroot
}

# Für ein SQL-String-Literal: \ und ' escapen
sql_escape() {
  local s=${1//\\/\\\\}
  printf '%s' "${s//\'/\'\'}"
}

# 1. Neues Passwort setzen, das bisherige bleibt als Secondary Password gültig
echo "1/4 MySQL: neues Passwort setzen, altes beibehalten"
mysql_root <<SQL
ALTER USER '$DB_USER'@'%' IDENTIFIED BY '$(sql_escape "$NEW_PASSWORD")' RETAIN CURRENT PASSWORD;
SQL

# 2. Secret patchen (über stdin, damit das Passwort nicht in der Prozessliste steht)
echo "2/4 Secret $SECRET auf Version $VERSION aktualisieren"
jq -n --arg p "$NEW_PASSWORD" --arg v "$VERSION" '{stringData: {password: $p, version: $v}}' \
  | kubectl patch secret "$SECRET" -n "$NAMESPACE" --type merge --patch-file /dev/stdin >/dev/null

# kubelet synchronisiert Secret-Volumes nur periodisch (bis ~1-2 min).
# Eine Pod-Änderung löst sofort einen Sync aus.
PODS=$(kubectl get pods -n "$NAMESPACE" -l app="$APP" --field-selector=status.phase=Running -o name)
for pod in $PODS; do
  kubectl annotate "$pod" -n "$NAMESPACE" db-credentials/version="$VERSION" --overwrite >/dev/null
done

# 3. Warten, bis jeder Pod die neue Version aktiv hat
echo "3/4 Warte auf Umstellung der Pods"
deadline=$((SECONDS + TIMEOUT))
for pod in $PODS; do
  echo -n "    $pod "
  until status=$(kubectl exec "$pod" -n "$NAMESPACE" -c "$APP" -- \
        curl -sf localhost:8080/actuator/dbcredentials 2>/dev/null) \
      && [[ $(jq -r .version <<<"$status") == "$VERSION" ]]; do
    if ((SECONDS > deadline)); then
      echo
      echo "Timeout: $pod hat nach ${TIMEOUT}s nicht umgestellt." >&2
      echo "Beide Passwörter bleiben gültig. Logs: kubectl logs $pod -n $NAMESPACE -c $APP" >&2
      exit 1
    fi
    echo -n "."
    sleep 2
  done
  echo " ok $(jq -c '{active, idle, total, waiting}' <<<"$status")"
done

# 4. Altes Passwort verwerfen. Bestehende Sessions bleiben davon unberührt,
#    alte Pool-Verbindungen werden bei Rückgabe an den Pool geschlossen.
echo "4/4 MySQL: altes Passwort verwerfen"
mysql_root <<SQL
ALTER USER '$DB_USER'@'%' DISCARD OLD PASSWORD;
SQL

echo "Fertig: Passwort rotiert (Version $VERSION)"
