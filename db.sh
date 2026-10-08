#!/usr/bin/env bash
set -euo pipefail

CONTAINER_NAME=mysql-pool
IMAGE=mysql:9.7
VOLUME=mysql-pool-data
DB_NAME=pool
DB_USER=pool
DB_PASSWORD=poolsecret
ROOT_PASSWORD=rootsecret
PORT=3306

# Container läuft bereits
if docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
  echo "Container $CONTAINER_NAME läuft bereits."
# Container existiert, ist aber gestoppt
elif docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
  echo "Starte vorhandenen Container $CONTAINER_NAME ..."
  docker start "$CONTAINER_NAME" >/dev/null
else
  echo "Erstelle Container $CONTAINER_NAME ($IMAGE) ..."
  docker run -d \
    --name "$CONTAINER_NAME" \
    -p "$PORT":3306 \
    -e MYSQL_ROOT_PASSWORD="$ROOT_PASSWORD" \
    -e MYSQL_DATABASE="$DB_NAME" \
    -e MYSQL_USER="$DB_USER" \
    -e MYSQL_PASSWORD="$DB_PASSWORD" \
    -v "$VOLUME":/var/lib/mysql \
    "$IMAGE" >/dev/null
fi

# Warten, bis MySQL Verbindungen annimmt
# -h 127.0.0.1 erzwingt TCP: Der temporäre Init-Server läuft ohne Netzwerk
# und wird so nicht fälschlich als "bereit" erkannt.
echo -n "Warte auf MySQL "
for _ in $(seq 1 60); do
  if docker exec "$CONTAINER_NAME" mysql -h 127.0.0.1 -uroot -p"$ROOT_PASSWORD" -e 'SELECT 1' >/dev/null 2>&1; then
    echo
    # Erlaubt dem App-User RETAIN CURRENT / DISCARD OLD PASSWORD am eigenen
    # Account, damit change-password.sh ohne root auskommt
    docker exec "$CONTAINER_NAME" mysql -h 127.0.0.1 -uroot -p"$ROOT_PASSWORD" \
      -e "GRANT APPLICATION_PASSWORD_ADMIN ON *.* TO '$DB_USER'@'%'" 2>/dev/null
    echo "MySQL ist bereit: jdbc:mysql://localhost:$PORT/$DB_NAME (User: $DB_USER)"
    exit 0
  fi
  echo -n "."
  sleep 2
done

echo
echo "MySQL ist nach 120 Sekunden nicht bereit. Logs: docker logs $CONTAINER_NAME" >&2
exit 1
