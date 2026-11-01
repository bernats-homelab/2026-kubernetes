#!/usr/bin/env bash
# Valida manifests contra os schemas do Kubernetes e boas práticas.
#   validate-manifests.sh            -> manifests do repo (pre-commit)
#   validate-manifests.sh upstream   -> charts upstream renderizados (CI, precisa de rede)
# Os schemas são baixados na primeira execução e ficam em cache em .cache/kubeconform.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
# Mesma minor do k3s fixado em ansible/group_vars/all/main.yaml
readonly KUBERNETES_VERSION="1.37.0"
readonly CACHE_DIR="${REPO_ROOT}/.cache/kubeconform"
readonly CRD_SCHEMAS='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'

mkdir -p "${CACHE_DIR}"

kubeconform_args=(
  -strict
  -summary
  -kubernetes-version "${KUBERNETES_VERSION}"
  -cache "${CACHE_DIR}"
  -schema-location default
  -schema-location "${CRD_SCHEMAS}"
)

case "${1:-local}" in
  local)
    "${REPO_ROOT}/scripts/render-manifests.sh" local | kubeconform "${kubeconform_args[@]}" -
    while read -r dir; do
      "${REPO_ROOT}/scripts/kustomize-build.sh" "${dir}" |
        kube-linter lint --config "${REPO_ROOT}/.kube-linter.yaml" -
    done < <(find "${REPO_ROOT}/kubernetes/workloads" -name kustomization.yaml -printf '%h\n' | sort)
    ;;
  upstream)
    # CRDs de terceiros sem schema no catálogo não devem bloquear; os recursos core continuam estritos.
    "${REPO_ROOT}/scripts/render-manifests.sh" upstream |
      kubeconform "${kubeconform_args[@]}" -ignore-missing-schemas -
    ;;
  *)
    echo "uso: $0 [local|upstream]" >&2
    exit 2
    ;;
esac
