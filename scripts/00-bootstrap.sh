#!/usr/bin/env sh
. "$(dirname "$0")/_lib.sh"

K3S_IMAGE="rancher/k3s:v1.36.5-k3s1"

if k3d cluster get "$CLUSTER_NAME" >/dev/null 2>&1; then
  log "k3d cluster '$CLUSTER_NAME' exists, making sure it is running"
  k3d cluster start "$CLUSTER_NAME" --wait --timeout 300s
else
  log "Creating k3d cluster '$CLUSTER_NAME' (1 server + 4 agents, $K3S_IMAGE)"
  k3d cluster create "$CLUSTER_NAME" \
    --image "$K3S_IMAGE" \
    --servers 1 --agents 4 \
    --api-port "0.0.0.0:${API_PORT}" \
    --port "${INGRESS_PORT}:80@loadbalancer" \
    --k3s-arg "--tls-san=host.docker.internal@server:*" \
    --kubeconfig-update-default=false --kubeconfig-switch-context=false \
    --wait --timeout 300s
fi

log "Writing kubeconfig (API reached via host.docker.internal:${API_PORT})"
k3d kubeconfig get "$CLUSTER_NAME" > /kube/config.tmp
kubectl --kubeconfig /kube/config.tmp config set-cluster "k3d-${CLUSTER_NAME}" \
  --server "https://host.docker.internal:${API_PORT}" >/dev/null
mv /kube/config.tmp /kube/config
chmod 600 /kube/config

log "Waiting for 4 Ready worker nodes"
i=0
until [ "$(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' --no-headers 2>/dev/null | grep -c ' Ready ')" -ge 4 ]; do
  i=$((i + 1)); [ "$i" -le 60 ] || { kubectl get nodes; echo "workers not Ready after 5 minutes" >&2; exit 1; }
  sleep 5
done

log "Simulating production nodepools (provided troubleshoot/prepare.sh)"
sh troubleshoot/prepare.sh

log "Pinning Traefik to the server node"
kubectl apply -f cluster/traefik-config.yaml

log "Cluster ready"
