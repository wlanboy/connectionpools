#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
source ./config.env

IMAGE="$REGISTRY/pool:latest"
NAMESPACE="pool"

echo "==> Baue Image (Dockerfile) ..."
docker build -f Dockerfile -t pool .

echo "==> Tagge Image als $IMAGE ..."
docker tag pool "$IMAGE"

echo "==> Push Image nach $IMAGE ..."
docker push "$IMAGE"

echo "==> Helm-Upgrade pool (MySQL $DB_HOST:$DB_PORT) ..."
helm upgrade pool ./pool-chart -n "$NAMESPACE" \
  --set image.repository="${IMAGE%:*}" \
  --set-string image.tag=latest \
  --set-string database.host="$DB_HOST" \
  --set database.port="$DB_PORT"

echo "==> Rollout-Restart pool ..."
kubectl rollout restart deployment/pool -n "$NAMESPACE"

echo
echo "Fertig."
