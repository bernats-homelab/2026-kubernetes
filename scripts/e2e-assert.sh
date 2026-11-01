#!/usr/bin/env bash
# Asserções do e2e (CI) contra o k3s local do runner.
set -euo pipefail

kubectl() { sudo /usr/local/bin/k3s kubectl "$@"; }

echo "==> node Ready"
kubectl wait --for=condition=Ready node --all --timeout=300s

for app in root argocd hello-world; do
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
echo "OK: e2e passou."
