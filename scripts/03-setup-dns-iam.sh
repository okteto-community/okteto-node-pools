#!/usr/bin/env bash
# Grant cert-manager permission to solve DNS-01 challenges in Cloud DNS.
#
# This is the only step needing IAM rights. It creates a dedicated service
# account, grants it DNS admin, and binds it to cert-manager's Kubernetes
# ServiceAccount through Workload Identity (enabled by 01-create-cluster.sh).
#
# No service account keys are created and nothing is written to disk.
#
# Usage:
#   PROJECT=my-project ./03-setup-dns-iam.sh
set -euo pipefail

PROJECT="${PROJECT:?set PROJECT to your GCP project id}"
GSA_NAME="${GSA_NAME:-cert-manager-dns01}"
GSA="${GSA_NAME}@${PROJECT}.iam.gserviceaccount.com"
KSA="${KSA:-cert-manager/cert-manager}"   # namespace/name
ZONE="${ZONE:-us-central1-a}"
CLUSTER="${CLUSTER:-okteto-nodepools}"

SDK_BIN="$(gcloud info --format='value(installation.sdk_root)' 2>/dev/null)/bin"
[ -x "$SDK_BIN/gke-gcloud-auth-plugin" ] && export PATH="$SDK_BIN:$PATH"

echo "==> Creating service account $GSA"
gcloud iam service-accounts create "$GSA_NAME" \
  --project "$PROJECT" \
  --display-name "cert-manager DNS01 solver ($CLUSTER)" \
  || echo "(already exists, continuing)"

# roles/dns.admin at project scope. It can be narrowed to a single zone, but
# cert-manager also needs project-level dns.managedZones.list.
echo "==> Granting roles/dns.admin"
gcloud projects add-iam-policy-binding "$PROJECT" \
  --member "serviceAccount:${GSA}" \
  --role roles/dns.admin \
  --condition=None >/dev/null

echo "==> Binding Workload Identity: ${KSA} -> ${GSA}"
gcloud iam service-accounts add-iam-policy-binding "$GSA" \
  --project "$PROJECT" \
  --role roles/iam.workloadIdentityUser \
  --member "serviceAccount:${PROJECT}.svc.id.goog[${KSA}]" >/dev/null

echo "==> Annotating the cert-manager ServiceAccount"
gcloud container clusters get-credentials "$CLUSTER" --zone "$ZONE" --project "$PROJECT"
kubectl annotate serviceaccount "${KSA##*/}" -n "${KSA%%/*}" \
  "iam.gke.io/gcp-service-account=${GSA}" --overwrite

echo "==> Restarting cert-manager so it picks up the identity"
kubectl rollout restart deployment cert-manager -n cert-manager
kubectl rollout status deployment cert-manager -n cert-manager --timeout=180s

echo
echo "Done. Next: kubectl apply -f cert-manager.yaml"
