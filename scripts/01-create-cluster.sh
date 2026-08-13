#!/usr/bin/env bash
# Create a GKE cluster with three dedicated Okteto node pools.
#
#   okteto -> Okteto control plane. NOT tainted: it is the cluster's default
#             pool, so GKE system workloads (kube-dns, metrics-server) keep a
#             home. Tainting all three pools breaks the cluster.
#   dev    -> user workloads / dev environments. Labeled + tainted.
#   build  -> BuildKit. Labeled + tainted.
#
# Sizing follows the Okteto GKE install guide: n2-standard-4, 250 GB disks.
#
# Usage:
#   PROJECT=my-project SUBDOMAIN=okteto.example.com ./01-create-cluster.sh
set -euo pipefail

PROJECT="${PROJECT:?set PROJECT to your GCP project id}"
ZONE="${ZONE:-us-central1-a}"
CLUSTER="${CLUSTER:-okteto-nodepools}"
MACHINE="${MACHINE:-n2-standard-4}"
DISK_SIZE="${DISK_SIZE:-250}"

# Pinned deliberately. Okteto supports Kubernetes 1.33 through 1.35, but GKE's
# REGULAR channel also offers 1.36. Left to default you get an unsupported
# version. Check the current range in the Okteto docs before bumping this.
K8S_VERSION="${K8S_VERSION:-1.35.6-gke.1258000}"

gcloud config set project "$PROJECT"

echo "==> Enabling required APIs"
gcloud services enable container.googleapis.com compute.googleapis.com dns.googleapis.com \
  --project "$PROJECT"

echo "==> Creating cluster $CLUSTER, whose default pool is the okteto pool"
gcloud container clusters create "$CLUSTER" \
  --project "$PROJECT" \
  --zone "$ZONE" \
  --release-channel regular \
  --cluster-version "$K8S_VERSION" \
  --machine-type "$MACHINE" \
  --disk-type pd-balanced \
  --disk-size "$DISK_SIZE" \
  --num-nodes 2 \
  --enable-autoscaling --min-nodes 2 --max-nodes 4 \
  --node-labels okteto-node-pool=okteto \
  --workload-pool "${PROJECT}.svc.id.goog" \
  --enable-ip-alias \
  --addons HorizontalPodAutoscaling,HttpLoadBalancing \
  --logging=SYSTEM \
  --monitoring=SYSTEM

echo "==> Creating the dev pool"
gcloud container node-pools create dev \
  --project "$PROJECT" --cluster "$CLUSTER" --zone "$ZONE" \
  --machine-type "$MACHINE" --disk-type pd-balanced --disk-size "$DISK_SIZE" \
  --num-nodes 1 --enable-autoscaling --min-nodes 1 --max-nodes 3 \
  --node-labels okteto-node-pool=dev \
  --node-taints okteto-node-pool=dev:NoSchedule

echo "==> Creating the build pool"
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
