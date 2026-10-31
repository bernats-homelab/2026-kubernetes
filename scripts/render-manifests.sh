#!/usr/bin/env bash
# Renderiza manifests para validação (stdout, multi-documento).
#   render-manifests.sh local     -> chart app-of-apps (Tailscale on/off) + kustomize dos workloads (offline)
#   render-manifests.sh upstream  -> charts upstream (argo-cd, tailscale-operator) com nossos values (precisa de rede)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly APPS_CHART="${REPO_ROOT}/kubernetes/apps"

# chart_field <chart-key> <field> -> lê kubernetes/apps/values.yaml (fonte única das versões)
chart_field() {
  helm show values "${APPS_CHART}" | awk -v chart="$1" -v field="$2" '
    /^charts:/ { in_charts = 1; next }
    in_charts && /^[^[:space:]]/ { in_charts = 0 }
    in_charts && $0 ~ "^  " chart ":" { in_chart = 1; next }
    in_chart && /^  [^[:space:]]/ { in_chart = 0 }
    in_chart && $1 == field ":" { print $2; exit }
  '
}

render_local() {
  helm template apps "${APPS_CHART}"
  echo "---"
  helm template apps "${APPS_CHART}" --set tailscaleOperator.enabled=false
  for dir in base overlays/tailscale; do
    echo "---"
    kustomize build "${REPO_ROOT}/kubernetes/workloads/hello-world/${dir}"
  done
}

render_upstream() {
  # Isola o helm dos repos configurados pelo usuário (render hermético).
  local helm_home
  helm_home="$(mktemp -d)"
  trap 'rm -rf "${helm_home}"' RETURN
  export HELM_REPOSITORY_CONFIG="${helm_home}/repositories.yaml"
  export HELM_REPOSITORY_CACHE="${helm_home}/cache"

  local key
  for key in argocd tailscaleOperator; do
    # Mesmos release names/namespaces das Applications em kubernetes/apps/templates
    local release namespace
    case "${key}" in
      argocd) release=argocd namespace=argocd ;;
      tailscaleOperator) release=tailscale-operator namespace=tailscale ;;
    esac
    echo "---"
    helm template "${release}" "$(chart_field "${key}" chart)" \
      --namespace "${namespace}" \
      --repo "$(chart_field "${key}" repoURL)" \
      --version "$(chart_field "${key}" version)" \
      --values "${REPO_ROOT}/kubernetes/values/${release}.yaml" \
      --include-crds
  done
}

case "${1:-}" in
  local) render_local ;;
  upstream) render_upstream ;;
  *)
    echo "uso: $0 local|upstream" >&2
    exit 2
    ;;
esac
