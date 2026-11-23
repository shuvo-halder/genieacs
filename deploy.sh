#!/usr/bin/env bash
# GenieACS Kubernetes deploy script
#
# Use:
#   ./deploy.sh                          # cluster-er default StorageClass diye
#   STORAGE_CLASS=ceph-rbd ./deploy.sh   # nirdishto StorageClass diye
#   ./deploy.sh delete                   # app muchhe dey (PVC/data thake)
#
# Purono data migrate korte (purono cluster theke):
#   kubectl -n genieacs exec deploy/genieacs-mongo -- mongodump --db genieacs --archive --gzip > genieacs.archive.gz
# Notun cluster-e, Mongo ready hole:
#   kubectl -n genieacs exec -i deploy/genieacs-mongo -- mongorestore --archive --gzip --drop < genieacs.archive.gz
#   kubectl -n genieacs rollout restart deploy/genieacs-server deploy/genieacs-ui
set -euo pipefail
cd "$(dirname "$0")"
NS=genieacs

command -v kubectl >/dev/null || { echo "kubectl paoa jachche na"; exit 1; }

if [[ "${1:-}" == "delete" ]]; then
  kubectl delete -f 40-hpa.yaml -f 30-genieacs-ui.yaml -f 20-genieacs-server.yaml --ignore-not-found
  kubectl delete deploy/genieacs-mongo svc/genieacs-mongo networkpolicy/genieacs-mongo-allow-app-only -n "$NS" --ignore-not-found
  echo "PVC (genieacs-mongo-pvc) ar secret rakha hoyeche. Pura muchte: kubectl delete ns $NS"
  exit 0
fi

echo ">> Namespace"
kubectl apply -f 00-namespace.yaml

echo ">> JWT secret"
if kubectl -n "$NS" get secret genieacs-secrets >/dev/null 2>&1; then
  echo "   genieacs-secrets already ache, ager-ta-i thakche"
else
  kubectl -n "$NS" create secret generic genieacs-secrets \
    --from-literal=jwt-secret="$(openssl rand -hex 32)"
fi

echo ">> MongoDB"
if [[ -n "${STORAGE_CLASS:-}" ]]; then
  sed "s|#STORAGECLASS|storageClassName: ${STORAGE_CLASS}|" 10-mongo.yaml | kubectl apply -f -
else
  sed "/#STORAGECLASS/d" 10-mongo.yaml | kubectl apply -f -
fi
kubectl -n "$NS" rollout status deploy/genieacs-mongo --timeout=300s

echo ">> GenieACS server / UI / HPA"
kubectl apply -f 20-genieacs-server.yaml -f 30-genieacs-ui.yaml -f 40-hpa.yaml
kubectl -n "$NS" rollout status deploy/genieacs-server --timeout=300s
kubectl -n "$NS" rollout status deploy/genieacs-ui --timeout=300s

echo
kubectl -n "$NS" get pods,svc,pvc,hpa
cat <<MSG

Done. Node IP diye access:
  UI            http://<node-ip>:30030
  CWMP (CPE)    http://<node-ip>:30747
  File server   http://<node-ip>:30767
NBI (7557) bairer dike expose kora nai, cluster-er bhitore: genieacs-server.genieacs.svc:7557
MSG
