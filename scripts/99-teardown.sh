#!/usr/bin/env bash
# Tear down everything created by the other scripts: the GKE cluster, its
# PVC-backed disks, the DNS records, and the cert-manager service account.
#
# Prompts once before deleting unless FORCE=1.
#
# Usage:
#   PROJECT=my-project SUBDOMAIN=okteto.example.com DNS_ZONE=my-zone ./99-teardown.sh
set -euo pipefail

PROJECT="${PROJECT:?set PROJECT to your GCP project id}"
SUBDOMAIN="${SUBDOMAIN:?set SUBDOMAIN, e.g. okteto.example.com}"
DNS_ZONE="${DNS_ZONE:?set DNS_ZONE, the Cloud DNS managed zone name}"
ZONE="${ZONE:-us-central1-a}"
CLUSTER="${CLUSTER:-okteto-nodepools}"
GSA_NAME="${GSA_NAME:-cert-manager-dns01}"
GSA="${GSA_NAME}@${PROJECT}.iam.gserviceaccount.com"

cat <<EOF
About to delete:
  cluster          $CLUSTER (zone $ZONE, project $PROJECT)
  DNS records      *.${SUBDOMAIN} and ${SUBDOMAIN} (zone $DNS_ZONE)
  service account  $GSA
  plus any PVC-backed persistent disks belonging to the cluster

EOF

if [ "${FORCE:-0}" != "1" ]; then
  read -r -p "Type the cluster name to confirm: " CONFIRM
  [ "$CONFIRM" = "$CLUSTER" ] || { echo "Aborted."; exit 1; }
fi

# Deleting a GKE cluster does NOT delete the persistent disks backing its PVCs.
# Record them now, while they are still attached to the cluster's nodes, so we
# can clean them up afterwards. Node instance names embed a truncated form of
# the cluster name, hence the prefix match.
echo "==> Finding PVC-backed disks belonging to $CLUSTER"
PREFIX="gke-$(echo "$CLUSTER" | cut -c1-16)"
PVC_DISKS="$(gcloud compute disks list \
  --project "$PROJECT" --filter="zone:${ZONE}" \
  --format="value(name,users)" 2>/dev/null \
  | grep -F "$PREFIX" | awk '$1 ~ /^pvc-/ {print $1}' || true)"
if [ -n "$PVC_DISKS" ]; then
  echo "$PVC_DISKS" | sed 's/^/    /'
else
  echo "    none found"
fi

# Delete the cluster first so the ingress LoadBalancer is released before the
# DNS records that point at it are removed.
echo "==> Deleting cluster $CLUSTER"
gcloud container clusters delete "$CLUSTER" \
  --zone "$ZONE" --project "$PROJECT" --quiet \
  || echo "(cluster not found or already deleted)"

# Whatever survived the cluster deletion is now orphaned and still billing.
if [ -n "$PVC_DISKS" ]; then
  echo "==> Deleting orphaned PVC disks"
  for D in $PVC_DISKS; do
    gcloud compute disks delete "$D" --zone "$ZONE" --project "$PROJECT" --quiet \
      || echo "(disk $D already gone)"
  done
fi

echo "==> Deleting DNS records"
for NAME in "*.${SUBDOMAIN}." "${SUBDOMAIN}."; do
  gcloud dns record-sets delete "$NAME" \
    --project "$PROJECT" --zone "$DNS_ZONE" --type A --quiet \
    || echo "(record $NAME not found)"
done

# Remove the IAM binding BEFORE deleting the service account. Deleting the
# account first turns the binding into a `deleted:serviceAccount:...?uid=...`
# principal that no longer matches the plain email, leaving it stranded in the
# project policy.
echo "==> Removing roles/dns.admin from $GSA"
gcloud projects remove-iam-policy-binding "$PROJECT" \
  --member "serviceAccount:${GSA}" \
  --role roles/dns.admin \
  --condition=None >/dev/null 2>&1 \
  || echo "(no roles/dns.admin binding to remove)"

echo "==> Deleting service account $GSA"
gcloud iam service-accounts delete "$GSA" --project "$PROJECT" --quiet \
  || echo "(service account not found)"

echo
echo "Teardown complete. Worth a final check for anything left behind:"
echo "  gcloud compute disks list --project $PROJECT --filter=\"zone:${ZONE}\""
echo "  gcloud projects get-iam-policy $PROJECT --flatten=\"bindings[].members\" --filter=\"bindings.members:${GSA_NAME}\""
