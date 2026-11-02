#!/usr/bin/env bash
# Renderiza manifests para validação (stdout, multi-documento).
#   render-manifests.sh local     -> chart app-of-apps (Tailscale/NAS on/off) + kustomize dos workloads (offline, KSOPS via stub)
#   render-manifests.sh upstream  -> charts upstream (argo-cd, tailscale-operator, cloudnative-pg, immich) com nossos values (precisa de rede)
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

# workload_dirs -> toda kustomization em kubernetes/workloads/<app>/{base,overlays/*}
workload_dirs() {
  find "${REPO_ROOT}/kubernetes/workloads" -name kustomization.yaml -printf '%h\n' | sort
}

render_local() {
  helm template apps "${APPS_CHART}"
  echo "---"
  helm template apps "${APPS_CHART}" --set tailscaleOperator.enabled=false --set nasStorage.enabled=false \
    --set smokeApp.enabled=true
  echo "---"
  # Uma app externa de exemplo, para validar o template de Application (apps: {} por padrão)
  helm template apps "${APPS_CHART}" \
    --set apps.exemplo.repoURL=https://github.com/bernats-homelab/exemplo \
    --set apps.exemplo.targetRevision=v1.0.0 \
    --show-only templates/external-apps.yaml
  local dir
  while read -r dir; do
    echo "---"
    "${REPO_ROOT}/scripts/kustomize-build.sh" "${dir}"
  done < <(workload_dirs)
}

render_upstream() {
  # Isola o helm dos repos configurados pelo usuário (render hermético).
  local helm_home
  helm_home="$(mktemp -d)"
  trap 'rm -rf "${helm_home}"' RETURN
  export HELM_REPOSITORY_CONFIG="${helm_home}/repositories.yaml"
  export HELM_REPOSITORY_CACHE="${helm_home}/cache"
  export HELM_REGISTRY_CONFIG="${helm_home}/registry.json"

  local key
  for key in argocd tailscaleOperator cloudnativePg immich; do
    # Mesmos release names/namespaces das Applications em kubernetes/apps/templates
    local release namespace repo chart
    case "${key}" in
      argocd) release=argocd namespace=argocd ;;
      tailscaleOperator) release=tailscale-operator namespace=tailscale ;;
      cloudnativePg) release=cloudnative-pg namespace=cnpg-system ;;
      immich) release=immich namespace=immich ;;
    esac
    repo="$(chart_field "${key}" repoURL)"
    chart="$(chart_field "${key}" chart)"
    # Charts OCI são referenciados direto (oci://registry/path/chart), sem --repo.
    local source=(--repo "${repo}" "${chart}")
    [[ "${repo}" == oci://* ]] && source=("${repo}/${chart}")
    echo "---"
    helm template "${release}" "${source[@]}" \
      --namespace "${namespace}" \
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
