#!/usr/bin/env bash
# Rotiert das DB-Passwort ohne Downtime:
#  1. MySQL: neues Passwort setzen, altes bleibt gültig (Dual Password)
#  2. Kubernetes-Secret aktualisieren und Pods zum Volume-Sync anstoßen
#  3. Warten, bis jeder Pod das neue Secret sieht (Hikari liest es bei jeder neuen Verbindung)
#  4. MySQL: altes Passwort verwerfen
# Läuft als App-User selbst, ohne root. Voraussetzung (einmalig als root):
#   GRANT APPLICATION_PASSWORD_ADMIN ON *.* TO 'pool'@'%';
#
# Das neue Passwort wird vor Schritt 1 als pending-password im Secret abgelegt.
# Bricht das Skript ab, setzt ein erneuter Lauf genau diese Rotation fort,
# statt ein weiteres Passwort zu erzeugen. Sonst würde RETAIN CURRENT PASSWORD
# das Passwort verwerfen, mit dem die Pods noch arbeiten.
#
# Aufruf: ./change-password.sh [neues-passwort]   (ohne Argument: zufällig)
set -euo pipefail

source "$(dirname "$0")/config.env"

APP=pool
NAMESPACE=pool
SECRET=$APP-db
TIMEOUT=180

secret_value() {
  kubectl get secret "$SECRET" -n "$NAMESPACE" -o jsonpath="{.data.$1}" | base64 -d
}

DB_USER=$(secret_value username)
CURRENT_PASSWORD=$(secret_value password)
PENDING_PASSWORD=$(secret_value pending-password)

if [[ -n $(secret_value pending-username) ]]; then
  echo "Unterbrochener User-Wechsel gefunden. Erst ./change-user.sh erneut ausführen." >&2
  exit 1
fi

# SQL als App-User mit dem übergebenen Passwort ausführen
mysql_as() {
  MYSQL_PWD="$1" mysql -h "$DB_HOST" -P "$DB_PORT" -u"$DB_USER"
}

can_login() {
  mysql_as "$1" <<<'SELECT 1' >/dev/null 2>&1
}

# Für ein SQL-String-Literal: \ und ' escapen
sql_escape() {
  local s=${1//\\/\\\\}
  printf '%s' "${s//\'/\'\'}"
}

# Secret-Patch über stdin, damit das Passwort nicht in der Prozessliste steht
patch_secret() {
  kubectl patch secret "$SECRET" -n "$NAMESPACE" --type merge --patch-file /dev/stdin >/dev/null
}

if [[ -n $PENDING_PASSWORD ]]; then
  NEW_PASSWORD=$PENDING_PASSWORD
  VERSION=$(secret_value pending-version)
  echo "Unterbrochene Rotation gefunden, setze Version $VERSION fort"
  [[ $# -gt 0 ]] && echo "    Übergebenes Passwort wird ignoriert." >&2
else
  NEW_PASSWORD=${1:-$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 24)}
  VERSION=$(date +%Y%m%d%H%M%S)
  jq -n --arg p "$NEW_PASSWORD" --arg v "$VERSION" \
    '{stringData: {"pending-password": $p, "pending-version": $v}}' | patch_secret
fi

# 1. Neues Passwort setzen, das bisherige bleibt als Secondary Password gültig.
#    Klappt der Login mit dem neuen Passwort schon, lief dieser Schritt bereits.
echo "1/4 MySQL: neues Passwort setzen, altes beibehalten"
if can_login "$NEW_PASSWORD"; then
  echo "    bereits gesetzt"
elif can_login "$CURRENT_PASSWORD"; then
  mysql_as "$CURRENT_PASSWORD" <<SQL
ALTER USER USER() IDENTIFIED BY '$(sql_escape "$NEW_PASSWORD")' RETAIN CURRENT PASSWORD;
SQL
else
  echo "Login als $DB_USER weder mit aktuellem noch mit neuem Passwort möglich." >&2
  exit 1
fi

# 2. Secret patchen
echo "2/4 Secret $SECRET auf Version $VERSION aktualisieren"
jq -n --arg p "$NEW_PASSWORD" --arg v "$VERSION" '{stringData: {password: $p, version: $v}}' \
  | patch_secret

# kubelet synchronisiert Secret-Volumes nur periodisch (bis ~1-2 min).
# Eine Pod-Änderung löst sofort einen Sync aus. Auch Pods, die gerade starten,
# werden erfasst: Ihr Volume kann noch den alten Stand enthalten.
PODS=$(kubectl get pods -n "$NAMESPACE" -l app="$APP" \
  --field-selector=status.phase!=Succeeded,status.phase!=Failed -o name)
for pod in $PODS; do
  kubectl annotate "$pod" -n "$NAMESPACE" db-credentials/version="$VERSION" --overwrite >/dev/null
done

# 3. Warten, bis jedes Pod-Volume die neue Version enthält.
#    Ein noch startender Pod antwortet erst, wenn er läuft.
echo "3/4 Warte auf Secret-Sync in den Pods"
deadline=$((SECONDS + TIMEOUT))
pod_gone() {
  ! kubectl get "$1" -n "$NAMESPACE" >/dev/null 2>&1
}
pod_synced() {
  status=$(kubectl exec "$1" -n "$NAMESPACE" -c "$APP" -- \
      curl -sf localhost:8080/actuator/dbcredentials 2>/dev/null) \
    && [[ $(jq -r .version <<<"$status") == "$VERSION" ]]
}
for pod in $PODS; do
  echo -n "    $pod "
  until pod_synced "$pod"; do
    if pod_gone "$pod"; then
      echo " entfernt"
      continue 2
    fi
    if ((SECONDS > deadline)); then
      echo
      echo "Timeout: $pod sieht nach ${TIMEOUT}s nicht die neue Version." >&2
      echo "Beide Passwörter bleiben gültig. Logs: kubectl logs $pod -n $NAMESPACE -c $APP" >&2
      exit 1
    fi
    echo -n "."
    sleep 2
  done
  echo " ok $(jq -c '{active, idle, total, waiting}' <<<"$status")"
done

# 4. Altes Passwort verwerfen. Bestehende Sessions bleiben davon unberührt,
#    alte Pool-Verbindungen laufen bis zu ihrer maxLifetime weiter.
echo "4/4 MySQL: altes Passwort verwerfen"
mysql_as "$NEW_PASSWORD" <<SQL
ALTER USER USER() DISCARD OLD PASSWORD;
SQL

# Rotation abgeschlossen: pending-Einträge entfernen
jq -n '{data: {"pending-password": null, "pending-version": null}}' | patch_secret

echo "Fertig: Passwort rotiert (Version $VERSION)"
