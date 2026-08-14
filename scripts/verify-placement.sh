#!/usr/bin/env bash
# Check every Okteto pod against the pool label on the node it actually landed
# on. This catches a pod that carries the right selector but was scheduled
# somewhere else, which a `helm template` render cannot tell you.
#
# Exits non-zero if anything is mismatched or unpinned, so it can be used in CI.
#
# Usage:
#   ./verify-placement.sh              # checks the okteto namespace
#   NAMESPACE=my-dev-ns ./verify-placement.sh
set -euo pipefail

NAMESPACE="${NAMESPACE:-okteto}"

command -v kubectl >/dev/null || { echo "kubectl not found" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 not found" >&2; exit 1; }

NODES_JSON="$(mktemp)"; PODS_JSON="$(mktemp)"
trap 'rm -f "$NODES_JSON" "$PODS_JSON"' EXIT

kubectl get nodes -o json > "$NODES_JSON"
kubectl get pods -n "$NAMESPACE" -o json > "$PODS_JSON"

NODES_JSON="$NODES_JSON" PODS_JSON="$PODS_JSON" NAMESPACE="$NAMESPACE" python3 <<'PY'
import json, os, sys

nodes = {n['metadata']['name']: n['metadata']['labels'].get('okteto-node-pool', '(unlabeled)')
         for n in json.load(open(os.environ['NODES_JSON']))['items']}
pods = json.load(open(os.environ['PODS_JSON']))['items']
ns = os.environ['NAMESPACE']

print(f"Node pools: " + ", ".join(f"{p}={sum(1 for v in nodes.values() if v==p)}"
                                  for p in sorted(set(nodes.values()))))
print()
print(f"{'POD':<52} {'SELECTOR':<10} {'ACTUAL':<10} STATUS")
print('-' * 90)

problems = []
for p in sorted(pods, key=lambda x: x['metadata']['name']):
    if p['status']['phase'] not in ('Running', 'Pending'):
        continue
    name = p['metadata']['name']
    sel = (p['spec'].get('nodeSelector') or {}).get('okteto-node-pool', '(none)')
    node = p['spec'].get('nodeName')
    actual = nodes.get(node, '(unscheduled)')

    if sel == '(none)':
        status = 'UNPINNED'
        # The nginx controllers and reloader come from subcharts and need their
        # own scheduling blocks. Unpinned here usually means those are missing.
        hint = (' (subchart: set ingress-nginx / okteto-nginx / reloader keys)'
                if any(k in name for k in ('nginx-controller', 'reloader')) else '')
        problems.append((name, 'no okteto-node-pool selector' + hint))
    elif sel != actual:
        status = 'MISMATCH'
        problems.append((name, f'selector={sel} but running on {actual}'))
    else:
        status = 'ok'
    print(f"{name[:51]:<52} {sel:<10} {actual:<10} {status}")

print()
if problems:
    print(f"{len(problems)} problem(s) in namespace {ns}:")
    for name, why in problems:
        print(f"  - {name}: {why}")
    sys.exit(1)
print(f"All pods in namespace {ns} are on their intended pool.")
PY
