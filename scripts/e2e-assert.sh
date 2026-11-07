#!/usr/bin/env bash
# Asserções do e2e (CI) contra o k3s local do runner.
set -euo pipefail

kubectl() { sudo /usr/local/bin/k3s kubectl "$@"; }

echo "==> node Ready"
kubectl wait --for=condition=Ready node --all --timeout=300s

for app in root argocd hello-world cloudnative-pg immich-database immich obsidian k8s-app-smoke grocery-ops; do
  echo "==> Application ${app} Synced + Healthy"
  kubectl -n argocd wait "application/${app}" --for=create --timeout=300s
  kubectl -n argocd wait "application/${app}" --for=jsonpath='{.status.sync.status}'=Synced --timeout=600s
  kubectl -n argocd wait "application/${app}" --for=jsonpath='{.status.health.status}'=Healthy --timeout=600s
done

echo "==> Tailscale Operator ausente no CI"
if kubectl -n argocd get application/tailscale-operator >/dev/null 2>&1; then
  echo "ERRO: tailscale-operator não deveria existir com tailscaleOperator.enabled=false" >&2
  exit 1
fi

echo "==> hello-world responde via Service"
kubectl -n hello-world rollout status deployment/hello-world --timeout=300s
body="$(kubectl get --raw /api/v1/namespaces/hello-world/services/hello-world:http/proxy/)"
grep -q '^Hostname: hello-world-' <<<"${body}" || {
  echo "ERRO: resposta inesperada do hello-world:" >&2
  echo "${body}" >&2
  exit 1
}
echo "==> KSOPS: Secret do demo descriptografado pelo ArgoCD"
message="$(kubectl -n hello-world get secret hello-world-demo -o jsonpath='{.data.message}' | base64 -d)"
if [[ "${message}" != "olá do KSOPS" ]]; then
  echo "ERRO: hello-world-demo.message inesperado: '${message}'" >&2
  exit 1
fi
echo "==> Postgres do Immich (CNPG) pronto com as extensões"
kubectl -n immich wait cluster.postgresql.cnpg.io/immich-database --for=condition=Ready --timeout=600s
kubectl -n immich wait database.postgresql.cnpg.io/immich-database --for=jsonpath='{.status.applied}'=true --timeout=300s

echo "==> Immich responde /api/server/ping"
kubectl -n immich rollout status deployment/immich-server --timeout=600s
ping="$(kubectl get --raw /api/v1/namespaces/immich/services/immich-server:http/proxy/api/server/ping)"
grep -q '"res":"pong"' <<<"${ping}" || {
  echo "ERRO: resposta inesperada do Immich: ${ping}" >&2
  exit 1
}

echo "==> Obsidian (Selkies) serve a página web"
kubectl -n obsidian rollout status deployment/obsidian --timeout=600s
page="$(kubectl get --raw /api/v1/namespaces/obsidian/services/obsidian:http/proxy/)"
grep -qi '<html' <<<"${page}" || {
  echo "ERRO: resposta inesperada do Obsidian:" >&2
  head -c 500 <<<"${page}" >&2
  exit 1
}

echo "==> App externa (repotpl-k8s-app) no AppProject homelab-apps responde /healthz"
project="$(kubectl -n argocd get application/k8s-app-smoke -o jsonpath='{.spec.project}')"
if [[ "${project}" != "homelab-apps" ]]; then
  echo "ERRO: k8s-app-smoke está no project '${project}', esperado homelab-apps" >&2
  exit 1
fi
kubectl -n k8s-app-smoke rollout status deployment/app-template --timeout=300s
health="$(kubectl get --raw /api/v1/namespaces/k8s-app-smoke/services/app-template:http/proxy/healthz)"
if [[ "${health}" != "ok" ]]; then
  echo "ERRO: resposta inesperada da app externa: '${health}'" >&2
  exit 1
fi

echo "==> grocery-ops (Bemesko/grocery-ops, Nuxt) responde /healthz"
kubectl -n grocery-ops rollout status deployment/grocery-ops --timeout=300s
health="$(kubectl get --raw /api/v1/namespaces/grocery-ops/services/grocery-ops:http/proxy/healthz)"
if [[ "${health}" != "ok" ]]; then
  echo "ERRO: resposta inesperada do grocery-ops: '${health}'" >&2
  exit 1
fi
echo "OK: e2e passou."
