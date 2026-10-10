#!/usr/bin/env bash
# Schaltet die Anwendung ohne Downtime auf den anderen DB-User um (pool_a <-> pool_b).
# Beide User existieren dauerhaft mit festen Passwörtern (angelegt von db.sh),
# in der Datenbank ändert sich nichts:
#  1. Login als Ziel-User prüfen
#  2. Kubernetes-Secret auf diesen User umstellen und Pods zum Volume-Sync anstoßen
#  3. Warten, bis jeder Pod das neue Secret sieht (Hikari liest es bei jeder neuen Verbindung)
# Offene Verbindungen des bisherigen Users laufen bis zu ihrer maxLifetime weiter.
#
# Der Ziel-User wird vor Schritt 1 als pending-username im Secret abgelegt.
# Bricht das Skript ab, setzt ein erneuter Lauf genau diesen Wechsel fort,
# statt wieder zurückzuschalten.
#
# Aufruf: ./change-user.sh
set -euo pipefail

source "$(dirname "$0")/config.env"

APP=pool
NAMESPACE=pool
SECRET=$APP-db
TIMEOUT=180

# User und Passwörter wie in db.sh
declare -A PASSWORDS=(
  [${APP}_a]=poolsecret_a
  [${APP}_b]=poolsecret_b
)

secret_value() {
  kubectl get secret "$SECRET" -n "$NAMESPACE" -o jsonpath="{.data.$1}" | base64 -d
}

can_login() {
  MYSQL_PWD="$2" mysql -h "$DB_HOST" -P "$DB_PORT" -u"$1" \
    <<<'SELECT 1' >/dev/null 2>&1
}

# Secret-Patch über stdin, damit das Passwort nicht in der Prozessliste steht
patch_secret() {
  kubectl patch secret "$SECRET" -n "$NAMESPACE" --type merge --patch-file /dev/stdin >/dev/null
}

PENDING_USER=$(secret_value pending-username)

if [[ -n $PENDING_USER ]]; then
  NEW_USER=$PENDING_USER
  VERSION=$(secret_value pending-version)
  echo "Unterbrochenen Wechsel auf $NEW_USER gefunden, setze Version $VERSION fort"
else
  if [[ -n $(secret_value pending-password) ]]; then
    echo "Unterbrochene Passwort-Rotation gefunden. Erst ./change-password.sh erneut ausführen." >&2
    exit 1
  fi
  # Beim ersten Lauf ist der aktive User noch "pool", dann geht es zu pool_a
  if [[ $(secret_value username) == "${APP}_a" ]]; then NEW_USER=${APP}_b; else NEW_USER=${APP}_a; fi
  VERSION=$(date +%Y%m%d%H%M%S)
  jq -n --arg u "$NEW_USER" --arg v "$VERSION" \
    '{stringData: {"pending-username": $u, "pending-version": $v}}' | patch_secret
fi
NEW_PASSWORD=${PASSWORDS[$NEW_USER]}

# 1. Erst prüfen, ob der Ziel-User sich anmelden kann. Sonst würden neue
#    Verbindungen nach dem Umschalten fehlschlagen.
echo "1/3 MySQL: Login als $NEW_USER prüfen"
if ! can_login "$NEW_USER" "$NEW_PASSWORD"; then
  echo "Login als $NEW_USER nicht möglich. Wurde ./db.sh ausgeführt?" >&2
  exit 1
fi

# 2. Secret patchen: Username und Passwort gemeinsam, damit kubelet beide
#    in einem atomaren Schritt ins Volume schreibt
echo "2/3 Secret $SECRET auf $NEW_USER, Version $VERSION umstellen"
jq -n --arg u "$NEW_USER" --arg p "$NEW_PASSWORD" --arg v "$VERSION" \
  '{stringData: {username: $u, password: $p, version: $v}}' | patch_secret

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
echo "3/3 Warte auf Secret-Sync in den Pods"
deadline=$((SECONDS + TIMEOUT))
pod_gone() {
  ! kubectl get "$1" -n "$NAMESPACE" >/dev/null 2>&1
}
pod_synced() {
  status=$(kubectl exec "$1" -n "$NAMESPACE" -c "$APP" -- \
      curl -sf localhost:8080/actuator/dbcredentials 2>/dev/null) \
    && [[ $(jq -r .version <<<"$status") == "$VERSION" ]] \
    && [[ $(jq -r .username <<<"$status") == "$NEW_USER" ]]
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
      echo "Timeout: $pod sieht nach ${TIMEOUT}s nicht den neuen User." >&2
      echo "Logs: kubectl logs $pod -n $NAMESPACE -c $APP" >&2
      exit 1
    fi
    echo -n "."
    sleep 2
  done
  echo " ok $(jq -c '{username, active, idle, total, waiting}' <<<"$status")"
done

# Wechsel abgeschlossen: pending-Einträge entfernen
jq -n '{data: {"pending-username": null, "pending-version": null}}' | patch_secret

echo "Fertig: Pods nutzen $NEW_USER (Version $VERSION)"
