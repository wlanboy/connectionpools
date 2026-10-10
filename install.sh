#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
source ./db.env

APP=pool
NAMESPACE=pool
REGISTRY=localhost:5001
TAG=${TAG:-$(date +%Y%m%d%H%M%S)}
IMAGE=$REGISTRY/$APP

# 1. Image bauen, taggen, in die lokale Registry pushen
docker build -t "$APP:$TAG" .
docker tag "$APP:$TAG" "$IMAGE:$TAG"
docker tag "$APP:$TAG" "$IMAGE:latest"
docker push "$IMAGE:$TAG"
docker push "$IMAGE:latest"

# 2. MySQL erreichbar?
if ! timeout 3 bash -c "</dev/tcp/$DB_HOST/$DB_PORT" 2>/dev/null; then
  echo "MySQL unter $DB_HOST:$DB_PORT nicht erreichbar (db.env prüfen)." >&2
  exit 1
fi

# 3. Namespace mit Istio-Sidecar-Injection
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace "$NAMESPACE" istio-injection=enabled --overwrite

# 4. Helm Chart deployen (eindeutiger Tag erzwingt neuen Rollout)
helm upgrade --install "$APP" ./pool-chart -n "$NAMESPACE" \
  --set image.repository="$IMAGE" \
  --set-string image.tag="$TAG" \
  --set-string database.host="$DB_HOST" \
  --set database.port="$DB_PORT"
kubectl rollout status "deployment/$APP" -n "$NAMESPACE" --timeout=180s

echo "Fertig: http://pool.localhost/"
