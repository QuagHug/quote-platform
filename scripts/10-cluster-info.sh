#!/usr/bin/env sh
# Shows the simulated nodepools: labels, taints and what runs where.
. "$(dirname "$0")/_lib.sh"

log "Nodes and their pool labels"
kubectl get nodes -L acme.io/capacity -L acme.io/node-type

log "Taints"
kubectl get nodes -o custom-columns='NODE:.metadata.name,TAINTS:.spec.taints[*].key'

log "Ingress endpoint"
echo "From your machine:  curl http://localhost:${INGRESS_PORT}/api/quote"
