#!/usr/bin/env bash
# Install Okteto onto the three-pool GKE cluster, then wire up wildcard DNS.
#
# Usage:
#   PROJECT=my-project SUBDOMAIN=okteto.example.com DNS_ZONE=my-zone \
#   LICENSE_FILE=/path/to/okteto.license ./02-install-okteto.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PROJECT="${PROJECT:?set PROJECT to your GCP project id}"
SUBDOMAIN="${SUBDOMAIN:?set SUBDOMAIN, e.g. okteto.example.com}"
DNS_ZONE="${DNS_ZONE:?set DNS_ZONE, the Cloud DNS managed zone name}"
LICENSE_FILE="${LICENSE_FILE:?set LICENSE_FILE to your Okteto license file}"
ZONE="${ZONE:-us-central1-a}"
CLUSTER="${CLUSTER:-okteto-nodepools}"
CHART_VERSION="${CHART_VERSION:-1.47.0}"

# kubectl needs gke-gcloud-auth-plugin to talk to GKE. Some installs (homebrew's
# google-cloud-sdk among them) place it in the SDK bin dir, which is not on PATH.
SDK_BIN="$(gcloud info --format='value(installation.sdk_root)' 2>/dev/null)/bin"
[ -x "$SDK_BIN/gke-gcloud-auth-plugin" ] && export PATH="$SDK_BIN:$PATH"
command -v gke-gcloud-auth-plugin >/dev/null || {
  echo "gke-gcloud-auth-plugin not found. Run: gcloud components install gke-gcloud-auth-plugin" >&2
  exit 1
}

[ -f "$LICENSE_FILE" ] || { echo "license not found: $LICENSE_FILE" >&2; exit 1; }
# The license is a single base32 string; strip the trailing newline. It is
# passed with --set-string so it never lands in a values file on disk.
LICENSE="$(tr -d '\n' < "$LICENSE_FILE")"

echo "==> Targeting cluster $CLUSTER"
gcloud container clusters get-credentials "$CLUSTER" --zone "$ZONE" --project "$PROJECT"

echo "==> Rendering config for subdomain $SUBDOMAIN"
RENDERED="$(mktemp -t okteto-config)"
trap 'rm -f "$RENDERED"' EXIT
sed "s/SUBDOMAIN/${SUBDOMAIN}/" "$HERE/config.yaml" > "$RENDERED"

echo "==> Installing Okteto chart $CHART_VERSION"
helm repo add okteto https://charts.okteto.com >/dev/null 2>&1 || true
helm repo update okteto >/dev/null
helm upgrade --install okteto okteto/okteto \
  -f "$RENDERED" \
  --set-string license="$LICENSE" \
  --namespace okteto --create-namespace \
  --version "$CHART_VERSION" \
  --timeout 15m --wait

echo "==> Waiting for the ingress LoadBalancer IP"
for _ in $(seq 1 60); do
  IP="$(kubectl get service -n okteto \
    -l app.kubernetes.io/name=ingress-nginx,app.kubernetes.io/component=controller \
    -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  [ -n "${IP:-}" ] && break
  sleep 10
done
[ -n "${IP:-}" ] || { echo "timed out waiting for LoadBalancer IP" >&2; exit 1; }
echo "Ingress IP: $IP"

echo "==> Creating wildcard + apex A records for $SUBDOMAIN"
for NAME in "*.${SUBDOMAIN}." "${SUBDOMAIN}."; do
  gcloud dns record-sets create "$NAME" \
    --project "$PROJECT" --zone "$DNS_ZONE" --type A --ttl 60 --rrdatas "$IP" \
  || gcloud dns record-sets update "$NAME" \
    --project "$PROJECT" --zone "$DNS_ZONE" --type A --ttl 60 --rrdatas "$IP"
done

echo
echo "==> Placement check"
kubectl get pods -n okteto -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeName --no-headers
kubectl get nodes -L okteto-node-pool

echo
echo "Okteto will be available at: https://okteto.${SUBDOMAIN}"
