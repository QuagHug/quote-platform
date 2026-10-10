#!/bin/sh
. "$(dirname "$0")/_lib.sh"

TF_DIR=iac/cloudflare
K8S_DIR=iac/karpenter
K8S_SCHEMAS="$K8S_DIR/schemas/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json"

export TF_DATA_DIR="${TMPDIR:-/tmp}/quote-tf/cloudflare"
KUBECONFORM_CACHE="${TMPDIR:-/tmp}/quote-kubeconform-cache"
mkdir -p "$TF_DATA_DIR" "$KUBECONFORM_CACHE"

failed=""

log "terraform fmt -check ($TF_DIR)"
if terraform -chdir="$TF_DIR" fmt -check -recursive -diff; then
  echo "fmt: ok"
else
  failed="$failed fmt"
fi

log "terraform init -backend=false ($TF_DIR)"
if terraform -chdir="$TF_DIR" init -backend=false -input=false -lockfile=readonly -no-color; then
  log "terraform validate ($TF_DIR)"
  terraform -chdir="$TF_DIR" validate -no-color || failed="$failed validate"
else
  echo "terraform init failed. It downloads the Cloudflare provider from registry.terraform.io, so it needs internet access (no Cloudflare token is needed). validate was skipped." >&2
  failed="$failed init"
fi

log "kubeconform -strict ($K8S_DIR) against the vendored Karpenter v1.15.0 schemas"
if ! kubeconform -strict -summary -cache "$KUBECONFORM_CACHE" \
  -ignore-filename-pattern '/schemas/' \
  -schema-location "$K8S_SCHEMAS" \
  -schema-location default \
  "$K8S_DIR"; then
  echo "kubeconform failed. Karpenter kinds are checked against $K8S_DIR/schemas offline. Core Kubernetes kinds, if any are added, fetch schemas from raw.githubusercontent.com on the first run and cache them in $KUBECONFORM_CACHE." >&2
  failed="$failed kubeconform"
fi

if [ -n "$failed" ]; then
  log "FAIL:$failed"
  exit 1
fi
log "PASS: terraform fmt, init, validate and kubeconform"
