#!/usr/bin/env bash
# Create a GKE cluster with a default pool for system workloads plus three
# dedicated Okteto node pools.
#
#   default -> GKE system workloads (kube-dns, metrics-server) and cluster
#              add-ons such as cert-manager. Untainted and unlabeled.
#   okteto  -> Okteto control plane. Labeled + tainted.
#   dev     -> user workloads / dev environments. Labeled + tainted.
#   build   -> BuildKit. Labeled + tainted.
#
# Keeping a separate default pool is what lets all three Okteto pools be
# tainted. Something in the cluster has to stay schedulable for kube-dns and
# friends; if every pool is tainted the cluster breaks before Okteto is even
# installed.
#
# Okteto pool sizing follows the Okteto GKE install guide: n2-standard-4 with
# 250 GB disks. The default pool can be much smaller, it only carries add-ons.
#
# Usage:
#   PROJECT=my-project ./01-create-cluster.sh
set -euo pipefail

PROJECT="${PROJECT:?set PROJECT to your GCP project id}"
ZONE="${ZONE:-us-central1-a}"
CLUSTER="${CLUSTER:-okteto-nodepools}"
MACHINE="${MACHINE:-n2-standard-4}"
DISK_SIZE="${DISK_SIZE:-250}"
SYSTEM_MACHINE="${SYSTEM_MACHINE:-e2-standard-2}"
SYSTEM_DISK_SIZE="${SYSTEM_DISK_SIZE:-100}"

# Pinned deliberately. Okteto supports Kubernetes 1.33 through 1.35, but GKE's
# REGULAR channel also offers 1.36. Left to default you get an unsupported
# version. Check the current range in the Okteto docs before bumping this.
K8S_VERSION="${K8S_VERSION:-1.35.6-gke.1258000}"

gcloud config set project "$PROJECT"

echo "==> Enabling required APIs"
gcloud services enable container.googleapis.com compute.googleapis.com dns.googleapis.com \
  --project "$PROJECT"

echo "==> Creating cluster $CLUSTER with its default pool for system workloads"
gcloud container clusters create "$CLUSTER" \
  --project "$PROJECT" \
  --zone "$ZONE" \
  --release-channel regular \
  --cluster-version "$K8S_VERSION" \
  --machine-type "$SYSTEM_MACHINE" \
  --disk-type pd-balanced \
  --disk-size "$SYSTEM_DISK_SIZE" \
  --num-nodes 1 \
  --enable-autoscaling --min-nodes 1 --max-nodes 3 \
  --workload-pool "${PROJECT}.svc.id.goog" \
  --enable-ip-alias \
  --addons HorizontalPodAutoscaling,HttpLoadBalancing \
  --logging=SYSTEM \
  --monitoring=SYSTEM

echo "==> Creating the okteto pool (control plane)"
gcloud container node-pools create okteto \
  --project "$PROJECT" --cluster "$CLUSTER" --zone "$ZONE" \
  --machine-type "$MACHINE" --disk-type pd-balanced --disk-size "$DISK_SIZE" \
  --num-nodes 2 --enable-autoscaling --min-nodes 2 --max-nodes 4 \
  --node-labels okteto-node-pool=okteto \
  --node-taints okteto-node-pool=okteto:NoSchedule

echo "==> Creating the dev pool (user workloads)"
gcloud container node-pools create dev \
  --project "$PROJECT" --cluster "$CLUSTER" --zone "$ZONE" \
  --machine-type "$MACHINE" --disk-type pd-balanced --disk-size "$DISK_SIZE" \
  --num-nodes 1 --enable-autoscaling --min-nodes 1 --max-nodes 3 \
  --node-labels okteto-node-pool=dev \
  --node-taints okteto-node-pool=dev:NoSchedule

echo "==> Creating the build pool (BuildKit)"
gcloud container node-pools create build \
  --project "$PROJECT" --cluster "$CLUSTER" --zone "$ZONE" \
  --machine-type "$MACHINE" --disk-type pd-balanced --disk-size "$DISK_SIZE" \
  --num-nodes 1 --enable-autoscaling --min-nodes 1 --max-nodes 3 \
  --node-labels okteto-node-pool=build \
  --node-taints okteto-node-pool=build:NoSchedule

echo "==> Fetching credentials"
gcloud container clusters get-credentials "$CLUSTER" --zone "$ZONE" --project "$PROJECT"

kubectl get nodes -L okteto-node-pool

echo
echo "Done. Next: ./02-install-okteto.sh"
