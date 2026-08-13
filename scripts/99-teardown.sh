#!/usr/bin/env bash
# Tear down everything created by the other scripts: the GKE cluster, the DNS
# records, and the cert-manager service account.
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

EOF

if [ "${FORCE:-0}" != "1" ]; then
  read -r -p "Type the cluster name to confirm: " CONFIRM
  [ "$CONFIRM" = "$CLUSTER" ] || { echo "Aborted."; exit 1; }
fi

# Delete the cluster first so the ingress LoadBalancer is released before the
# DNS records that point at it are removed.
echo "==> Deleting cluster $CLUSTER"
gcloud container clusters delete "$CLUSTER" \
  --zone "$ZONE" --project "$PROJECT" --quiet \
  || echo "(cluster not found or already deleted)"

echo "==> Deleting DNS records"
for NAME in "*.${SUBDOMAIN}." "${SUBDOMAIN}."; do
  gcloud dns record-sets delete "$NAME" \
    --project "$PROJECT" --zone "$DNS_ZONE" --type A --quiet \
    || echo "(record $NAME not found)"
done

echo "==> Deleting service account $GSA"
gcloud iam service-accounts delete "$GSA" --project "$PROJECT" --quiet \
  || echo "(service account not found)"

# The project-level roles/dns.admin binding disappears with the service account
# principal, but the policy may keep a stale entry. Remove it explicitly.
gcloud projects remove-iam-policy-binding "$PROJECT" \
  --member "serviceAccount:${GSA}" \
  --role roles/dns.admin \
  --condition=None >/dev/null 2>&1 \
  || echo "(no roles/dns.admin binding to remove)"

echo
echo "Teardown complete."
