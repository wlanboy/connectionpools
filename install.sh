#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

APP=pool
NAMESPACE=pool
REGISTRY=localhost:5001
TAG=${TAG:-$(date +%Y%m%d%H%M%S)}
IMAGE=$REGISTRY/$APP
DB_CONTAINER=mysql-pool
KIND_NETWORK=kind

# 1. Image bauen, taggen, in die lokale Registry pushen
docker build -t "$APP:$TAG" .
docker tag "$APP:$TAG" "$IMAGE:$TAG"
docker tag "$APP:$TAG" "$IMAGE:latest"
docker push "$IMAGE:$TAG"
docker push "$IMAGE:latest"

# 2. MySQL-Container ins kind-Netzwerk hängen, damit Pods ihn erreichen
if ! docker inspect -f '{{json .NetworkSettings.Networks}}' "$DB_CONTAINER" | grep -q "\"$KIND_NETWORK\""; then
  docker network connect "$KIND_NETWORK" "$DB_CONTAINER"
fi

# 3. Namespace mit Istio-Sidecar-Injection
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace "$NAMESPACE" istio-injection=enabled --overwrite

# 4. Helm Chart deployen (eindeutiger Tag erzwingt neuen Rollout)
helm upgrade --install "$APP" ./pool-chart -n "$NAMESPACE" \
  --set image.repository="$IMAGE" \
  --set image.tag="$TAG"
kubectl rollout status "deployment/$APP" -n "$NAMESPACE" --timeout=180s

echo "Fertig: http://pool.localhost/"
