# Okteto on GKE with three dedicated node pools

Reference configuration for running Okteto Self-Hosted with its workloads split
across three dedicated node pools, plus a real Let's Encrypt wildcard certificate.

| pool | runs | labeled | tainted |
|---|---|---|---|
| `default` | GKE system workloads (kube-dns, metrics-server) and add-ons such as cert-manager | no | no |
| `okteto` | control plane: api, frontend, webhook, registry, both nginx controllers, all jobs and cronjobs | yes | yes |
| `dev` | user workloads: dev environments, deployed namespaces, `okteto up` containers, the Okteto daemonset | yes | yes |
| `build` | BuildKit | yes | yes |

Why bother: BuildKit is resource hungry and will happily starve the control
plane, and user workloads are untrusted and unpredictable. Separating the three
means a runaway build or a broken dev environment cannot take down the Okteto API.

Keeping the cluster's default pool separate is what lets all three Okteto pools
be tainted. Something has to stay schedulable for `kube-dns` and friends.

## Tested with

| component | version |
|---|---|
| Okteto Helm chart | 1.47.0 |
| Kubernetes (GKE) | 1.35.6-gke.1258000 |
| cert-manager | v1.21.1 |
| Okteto CLI | 3.21.0 |

Okteto supports Kubernetes 1.33 through 1.35. GKE's REGULAR channel also offers
1.36, which is outside that range, so `01-create-cluster.sh` pins the version
rather than taking the channel default. Check the supported range in the
[Okteto docs](https://www.okteto.com/docs/get-started/install/google-gke/)
before bumping it.

## Contents

| file | purpose |
|---|---|
| `config.yaml` | Okteto Helm values, three-pool scheduling |
| `config-letsencrypt.yaml` | values overlay swapping the self-signed cert for Let's Encrypt |
| `cert-manager.yaml` | ClusterIssuer + wildcard Certificate |
| `scripts/01-create-cluster.sh` | GKE cluster and the node pools |
| `scripts/02-install-okteto.sh` | Okteto chart install and wildcard DNS records |
| `scripts/03-setup-dns-iam.sh` | Workload Identity so cert-manager can solve DNS-01 |
| `scripts/verify-placement.sh` | check every pod against the pool it actually landed on |
| `scripts/99-teardown.sh` | delete the cluster, DNS records and service account |

## Prerequisites

- `gcloud`, `kubectl` >= 1.28, `helm` >= 3.14, and `gke-gcloud-auth-plugin`
- The `okteto` CLI, for the verification step
- An Okteto license
- A domain in Cloud DNS you can add wildcard records to

## Walkthrough

### 1. Create the cluster and pools

```bash
export PROJECT=my-gcp-project
export SUBDOMAIN=okteto.example.com
export DNS_ZONE=my-cloud-dns-zone

./scripts/01-create-cluster.sh
```

This creates a zonal cluster with a small untainted default pool for system
workloads, then adds `okteto`, `dev` and `build` as labeled, tainted pools. The
three Okteto pools use `n2-standard-4` with 250 GB disks, the sizing the Okteto
GKE install guide recommends. The default pool only carries add-ons, so it is
smaller (`e2-standard-2`).

The node labels and taints are the contract the Helm values depend on:

| pool | label | taint |
|---|---|---|
| `default` | none | none |
| `okteto` | `okteto-node-pool=okteto` | `okteto-node-pool=okteto:NoSchedule` |
| `dev` | `okteto-node-pool=dev` | `okteto-node-pool=dev:NoSchedule` |
| `build` | `okteto-node-pool=build` | `okteto-node-pool=build:NoSchedule` |

> **Leave the default pool untainted.** Taint every pool in the cluster and
> GKE's own system workloads have nowhere to schedule, breaking the cluster
> before Okteto is even installed. Anything without an `okteto-node-pool`
> selector, including cert-manager, lands here.

### 2. Install Okteto

```bash
export LICENSE_FILE=/path/to/your.license
./scripts/02-install-okteto.sh
```

The script substitutes your subdomain into `config.yaml`, installs the chart,
waits for the ingress LoadBalancer IP, and creates the wildcard and apex A
records. The license is passed with `--set-string`, so it is never written to a
values file on disk.

At this point Okteto works, but with a self-signed certificate. If that is fine
for your use case, stop here.

### 3. Install cert-manager

```bash
helm repo add jetstack https://charts.jetstack.io && helm repo update
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --version v1.21.1 --set crds.enabled=true --wait
```

### 4. Give cert-manager DNS-01 access

```bash
./scripts/03-setup-dns-iam.sh
```

Okteto needs a **wildcard** certificate, because every dev-environment endpoint
is a subdomain. Let's Encrypt only issues wildcards over DNS-01, so cert-manager
must be able to write TXT records in your zone. The script creates a dedicated
service account, grants `roles/dns.admin`, binds it to cert-manager's Kubernetes
ServiceAccount via Workload Identity, and restarts cert-manager. No service
account keys are created.

> Ambient node credentials are not a shortcut here. Even when the node service
> account holds a broad role, default GKE node OAuth scopes do not include DNS,
> so the metadata token cannot call the Cloud DNS API.

### 5. Issue the certificate and switch Okteto onto it

Replace `GCP_PROJECT`, `EMAIL` and `SUBDOMAIN` in `cert-manager.yaml`, then:

```bash
kubectl apply -f cert-manager.yaml
kubectl wait --for=condition=Ready certificate/default-ssl-certificate -n okteto --timeout=10m
```

Issuance takes a few minutes while the DNS-01 challenge propagates. Then switch
Okteto over:

```bash
helm upgrade okteto okteto/okteto \
  -f config.yaml -f config-letsencrypt.yaml \
  --set-string license="$(tr -d '\n' < "$LICENSE_FILE")" \
  --namespace okteto --version 1.47.0 --wait
```

## Verifying placement

Rendering the chart with `helm template` only tells you what the *selectors*
say. It cannot tell you where a pod actually ended up. Check the cluster.

### Control plane

List the Okteto pods with the node each one is on, then compare against the pool
labels on those nodes:

```bash
kubectl get pods -n okteto -o wide
kubectl get nodes -L okteto-node-pool
```

Every pod in the `okteto` namespace should sit on an `okteto` node, except the
two daemonsets (`okteto-daemon`, `okteto-prepullimages`) which belong on `dev`,
and `okteto-buildkit` which belongs on `build`.

To check a single pod's intended pool:

```bash
kubectl get pod -n okteto <pod> -o jsonpath='{.spec.nodeSelector}{"\n"}{.spec.tolerations}'
```

`scripts/verify-placement.sh` does this comparison for every pod and exits
non-zero if anything is unpinned or landed on the wrong pool:

```bash
./scripts/verify-placement.sh
```

### User workloads

The important check is that a real application lands on the `dev` pool. Deploy
one through Okteto rather than with `kubectl`, so it goes through the same path
your users will take:

```bash
okteto context use https://okteto.$SUBDOMAIN
okteto namespace create pooltest
okteto pipeline deploy --repository https://github.com/okteto/movies --name movies --wait
```

Then confirm where it landed:

```bash
NAMESPACE=pooltest ./scripts/verify-placement.sh
kubectl get pods -n pooltest -o wide
```

Every pod should report `okteto-node-pool=dev` and be running on a `dev` node.
On our test cluster all eight services of
[okteto/movies](https://github.com/okteto/movies) (api, catalog, frontend, kafka,
mongodb, postgresql, rent, worker) scheduled onto the dev pool.

Clean up:

```bash
okteto namespace delete pooltest
```

## Known limitation: the nginx and reloader subcharts

`globals.nodeSelectors` and `globals.tolerations` pin the Okteto chart's own
workloads, but they are **not** applied to three components that come from
subcharts:

- `okteto-ingress-nginx-controller`
- `okteto-okteto-nginx-controller`
- `okteto-reloader`

Render the chart with only `globals` set and those three come out with no
`nodeSelector` and no `tolerations` at all. On a cluster where every Okteto pool
is tainted, they cannot schedule onto any of them: they land on whatever
untainted pool exists, or stay `Pending` if none does. Losing both ingress
controllers takes the instance down.

The cause is that Helm only propagates values under its reserved `global` key
into subcharts, and Okteto's key is `globals`, so subcharts never see it.

`config.yaml` works around this by pinning all three by hand. Keep those blocks
if you adapt this configuration. This has been reported to Okteto.

## Teardown

```bash
PROJECT=$PROJECT SUBDOMAIN=$SUBDOMAIN DNS_ZONE=$DNS_ZONE ./scripts/99-teardown.sh
```

Deletes the cluster, both DNS records and the cert-manager service account. It
prompts for confirmation; set `FORCE=1` to skip that.

## References

- [Okteto Helm configuration](https://www.okteto.com/docs/self-hosted/helm-configuration/)
- [Install Okteto on GKE](https://www.okteto.com/docs/get-started/install/google-gke/)
- [Configuring BuildKit for high performance](https://www.okteto.com/docs/self-hosted/manage/buildkit-high-performance/)
- [Certificates with cert-manager and Let's Encrypt](https://www.okteto.com/docs/self-hosted/install/certificates/cert-manager/)
