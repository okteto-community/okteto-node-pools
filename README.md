# Okteto on GKE with three dedicated node pools

Reference configuration for running Okteto Self-Hosted with its workloads split
across three dedicated node pools, plus a real Let's Encrypt wildcard certificate.

| pool | runs | tainted |
|---|---|---|
| `okteto` | control plane: api, frontend, webhook, registry, both nginx controllers, all jobs and cronjobs | no |
| `dev` | user workloads: dev environments, deployed namespaces, `okteto up` containers, the Okteto daemonset | yes |
| `build` | BuildKit | yes |

Why bother: BuildKit is resource hungry and will happily starve the control
plane, and user workloads are untrusted and unpredictable. Separating the three
means a runaway build or a broken dev environment cannot take down the Okteto API.

Everything here was validated end to end on a real GKE cluster: chart 1.47.0,
Kubernetes 1.35, cert-manager v1.21.1.

## Contents

| file | purpose |
|---|---|
| `config.yaml` | Okteto Helm values, three-pool scheduling |
| `config-letsencrypt.yaml` | values overlay swapping the self-signed cert for Let's Encrypt |
| `cert-manager.yaml` | ClusterIssuer + wildcard Certificate |
| `scripts/01-create-cluster.sh` | GKE cluster and the three node pools |
| `scripts/02-install-okteto.sh` | Okteto chart install and wildcard DNS records |
| `scripts/03-setup-dns-iam.sh` | Workload Identity so cert-manager can solve DNS-01 |

## Prerequisites

- `gcloud`, `kubectl` >= 1.28, `helm` >= 3.14
- `gke-gcloud-auth-plugin` (see gotcha 7 below)
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

This creates a zonal cluster whose **default pool is the `okteto` pool**, then
adds `dev` and `build` as tainted pools. All three use `n2-standard-4` with
250 GB disks, the sizing the Okteto GKE install guide recommends.

The node labels and taints are the contract the Helm values depend on:

| pool | label | taint |
|---|---|---|
| `okteto` | `okteto-node-pool=okteto` | none |
| `dev` | `okteto-node-pool=dev` | `okteto-node-pool=dev:NoSchedule` |
| `build` | `okteto-node-pool=build` | `okteto-node-pool=build:NoSchedule` |

> **Do not taint all three pools.** The `okteto` pool is the cluster's default
> pool. If every pool is tainted, GKE's own system workloads (`kube-dns`,
> `metrics-server`) have nowhere to schedule and the cluster is broken before
> Okteto is even installed.

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

Rendering the chart is not proof. Check what actually happened.

**Every pod against its node's real pool.** This compares each pod's selector to
the label on the node it actually landed on, which catches a pod that is pinned
but scheduled somewhere else:

```bash
kubectl get nodes -o json > /tmp/nodes.json
kubectl get pods -A -o json > /tmp/pods.json
python3 - <<'PY'
import json
nodes={n['metadata']['name']: n['metadata']['labels'].get('okteto-node-pool','(unlabeled)')
       for n in json.load(open('/tmp/nodes.json'))['items']}
for p in json.load(open('/tmp/pods.json'))['items']:
    if p['metadata']['namespace'] != 'okteto': continue
    if p['status']['phase'] not in ('Running','Pending'): continue
    sel=(p['spec'].get('nodeSelector') or {}).get('okteto-node-pool','(none)')
    actual=nodes.get(p['spec'].get('nodeName'),'(unscheduled)')
    flag='OK' if sel==actual else 'MISMATCH'
    print(f"{p['metadata']['name'][:50]:<52} {sel:<8} {actual:<8} {flag}")
PY
```

**User workloads really land on the dev pool.** The Okteto mutating webhook only
touches namespaces labeled `dev.okteto.com=true`, so reproduce that:

```bash
kubectl create namespace pooltest
kubectl label namespace pooltest dev.okteto.com=true
kubectl -n pooltest create deployment nginx --image=nginx:alpine
kubectl -n pooltest get pod -o jsonpath='{.items[0].spec.nodeSelector}'
# expect {"okteto-node-pool":"dev"} plus the matching toleration
kubectl delete namespace pooltest
```

**Prove the pinning is airtight with an empty fourth pool.** Add a pool with
zero nodes, labeled but **untainted**, and confirm it stays empty. A tainted
empty pool proves nothing; an untainted one attracts anything not properly
pinned:

```bash
gcloud container node-pools create spare \
  --cluster "$CLUSTER" --zone "$ZONE" --project "$PROJECT" \
  --machine-type n2-standard-4 --num-nodes 0 \
  --enable-autoscaling --min-nodes 0 --max-nodes 2 \
  --node-labels okteto-node-pool=spare

kubectl get nodes -l okteto-node-pool=spare -o name | wc -l   # expect 0
```

Expected steady state on a default install:

| pool | workloads |
|---|---|
| `dev` | `okteto-daemon`, `okteto-prepullimages`, plus every user pod |
| `build` | `okteto-buildkit` |
| `okteto` | everything else, including `okteto-registry` and all jobs/cronjobs |

## Gotchas

Each of these cost real debugging time.

**1. `wildcardCertificate.create: false` is not enough on its own.**
In the chart's `values.yaml`, ingress-nginx receives its default certificate as
a hardcoded string literal:

```yaml
ingress-nginx:
  controller:
    extraArgs:
      default-ssl-certificate: $(POD_NAMESPACE)/default-ssl-certificate-selfsigned
```

That literal does **not** derive from `wildcardCertificate.name`, unlike every
other consumer of the certificate. Helm cannot template subchart values, so it
cannot follow the rename on its own.

Set `create: false` alone and two things happen. The chart stops rendering the
`default-ssl-certificate-selfsigned` secret (it is gated on `create`), so nginx's
*default* certificate now points at a secret that does not exist and falls back
to nginx's built-in `Kubernetes Ingress Controller Fake Certificate`. Meanwhile
the chart-rendered ingresses (`okteto.`, `registry.`, `buildkit.`, `kubernetes.`
and the `*.SUBDOMAIN` wildcard) *do* get `secretName: default-ssl-certificate`
in their TLS blocks, so those hosts still serve the correct certificate over SNI.

So the breakage is narrow but genuinely confusing: cert-manager reports `Ready`,
your main hosts look fine, and only requests that do not match an ingress TLS
host hit the fake certificate. `config-letsencrypt.yaml` repoints the arg.
Verify with:

```bash
helm template okteto okteto/okteto -f config.yaml -f config-letsencrypt.yaml \
  | grep -c default-ssl-certificate-selfsigned   # must be 0
```

This *is* documented, but not where you would look for it. The
[cert-manager page](https://www.okteto.com/docs/self-hosted/install/certificates/cert-manager/)
is a stub that delegates to community forum guides, and those guides do carry the
`extraArgs` override. The Helm configuration reference, which is the natural
place to look, documents `wildcardCertificate.create` and `.name` with no mention
of the nginx arg. The community guides also take a slightly different route: they
name the secret `okteto-letsencrypt` and set both `wildcardCertificate.name` and
the nginx arg to match. This repo instead keeps the chart's default secret name
and overrides only the arg. Either works, as long as the two agree.

**2. The terse pool short form is deprecated, but only the chart tells you so.**
`tolerations.{oktetoPool,buildPool,devPool}` sets the nodeSelector and
auto-generates the matching toleration in three lines. Install with it and the
chart prints:

```
[WARNING] .Values.tolerations.[oktetoPool, devPool, buildPool] is deprecated
and will be removed in Okteto Chart 2.0.
```

That warning is the only place you will find out. The Helm configuration
reference has no entry for these values and never calls them deprecated, and
two of its own runnable examples (the daemonset and defaultBackend sections)
still teach the old form. The migration guide exists as a community post, but
nothing in the docs links to it, only the install-time warning does. The
BuildKit high-performance page is the clean exception: it already uses
`buildkit.nodeSelectors` / `buildkit.tolerations`.

This repo uses the replacement throughout. One behavioral difference worth
knowing: the short form also places `okteto-registry` on the build pool
(co-located with BuildKit for image push/pull locality), while the supported
form leaves it on the okteto pool, since there is no registry-specific selector.

**3. Ignore the docs note claiming `globals.nodeSelectors.dev` needs `tolerations.devPool`.**
The Helm reference states, in four separate places, that dev node selectors
"will not be applied to user workloads unless a `tolerations.devPool` value is
also set", calling it legacy behavior. Taken literally that is a trap: it tells
you to keep using the very value the chart warns is being removed.

On chart 1.47.0 it is also **not true**. Verified on a live cluster with
`tolerations.devPool` unset (`OKTETO_DEV_POOL: ""` in the configmap): every user
pod in an Okteto-managed namespace still received `nodeSelector:
okteto-node-pool=dev` plus the matching toleration, and landed on the dev pool.
The dev selectors are applied unconditionally; only the auto-generated taint
toleration was ever gated on `devPool`, which is why this config spells out
`globals.tolerations.dev` explicitly.

One related error in that same reference: it says to "define a `devPool` entry
in `globals.tolerations`". There is no such key. `globals.tolerations` takes
`okteto` and `dev` only.

**4. Subcharts ignore `globals` entirely.**
`ingress-nginx`, `okteto-nginx` and `reloader` are upstream subcharts. Render the
chart without pinning them and they come out with no `nodeSelector` at all. They
only stay off the tainted pools by luck. Pin all three by hand.

**5. `regcredsManager` uses `replicas`, not `replicaCount`.**
Set `replicaCount` everywhere else and this one silently stays at 2.

**6. GKE offers Kubernetes versions Okteto does not support.**
The REGULAR channel served 1.36 while Okteto supported 1.33 through 1.35. Pin
`--cluster-version` explicitly instead of taking the channel default.

**7. `gke-gcloud-auth-plugin` may not be on your PATH.**
`kubectl` cannot authenticate to GKE without it. Install with
`gcloud components install gke-gcloud-auth-plugin`. Some distributions (homebrew's
`google-cloud-sdk` among them) then leave the binary in the SDK's own `bin`
directory rather than symlinking it, so it is installed but still not found. The
scripts resolve it from the SDK root.

**8. The daemonset covers only dev pool nodes.**
The Okteto daemonset follows the `dev` selectors, so with a dedicated dev pool it
runs *only* there. Your okteto and build nodes get no daemonset. That daemonset
overrides kernel file-watcher limits, points registry hostname resolution at
internal IPs, configures kubelet with private-registry credentials, and installs
a private CA. Usually harmless, since file watchers only matter for dev
containers. But if you enable `configurePrivateRegistriesInNodes` or
`wildcardCertificate.privateCA`, the build and okteto nodes will not receive it.

**9. Installer jobs run on the okteto pool, not the dev pool.**
`okteto deploy` runs as an `installer-*` job in the `okteto` namespace, so the
dev-namespace mutating webhook never sees it and it inherits the okteto pool.
Your users' deploy commands therefore execute alongside the control plane. It is
bounded (small resource requests, `installer.activeDeadlineSeconds`), but it is
the one place user-authored code runs outside the dev pool.

## Teardown

```bash
gcloud container clusters delete "$CLUSTER" --zone "$ZONE" --project "$PROJECT"
gcloud dns record-sets delete "*.${SUBDOMAIN}." --type A --zone "$DNS_ZONE" --project "$PROJECT"
gcloud dns record-sets delete "${SUBDOMAIN}." --type A --zone "$DNS_ZONE" --project "$PROJECT"
gcloud iam service-accounts delete "cert-manager-dns01@${PROJECT}.iam.gserviceaccount.com" --project "$PROJECT"
```

## References

- [Okteto Helm configuration](https://www.okteto.com/docs/self-hosted/helm-configuration/)
- [Install Okteto on GKE](https://www.okteto.com/docs/get-started/install/google-gke/)
- [Configuring BuildKit for high performance](https://www.okteto.com/docs/self-hosted/manage/buildkit-high-performance/)
- [Certificates with cert-manager and Let's Encrypt](https://www.okteto.com/docs/self-hosted/install/certificates/cert-manager/)
