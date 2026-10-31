#!/usr/bin/env bash
# Prepara a máquina de controle (WSL Ubuntu nesta máquina, ou o runner do CI):
# ferramentas com versão e sha256 fixados em ~/.local/bin + coleções Ansible.
set -euo pipefail

readonly BIN_DIR="${HOME}/.local/bin"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT

# --- versões fixadas (atualize versão + sha256 juntos) -----------------------
readonly ANSIBLE_CORE_VERSION="2.21.5"
readonly ANSIBLE_LINT_VERSION="26.10.1"
readonly PRE_COMMIT_VERSION="4.7.0"
readonly KUBERNETES_PY_VERSION="37.0.1"

readonly SOPS_VERSION="v3.13.3"
readonly SOPS_SHA256="e5bec3346a873ae91d871550f3e698c1aad962aff462a080e40f25fde17fef6b"
readonly AGE_VERSION="v1.3.2"
readonly AGE_SHA256="cbe24006683f8eb669266162894b9a522a1af52f2665fbc63a4bb032ed26ac10"
readonly HELM_VERSION="v4.3.1"
readonly HELM_SHA256="0403a88ae20913d11b10a2467b50087721fea7581736da6b9d3992f5357fe54b"
readonly KUBECTL_VERSION="v1.37.1"
readonly KUBECTL_SHA256="65691ff77eb6fa44c908b77a1082c9f092c3b9733b5cefabec0d1104890e21a8"
readonly KUBECONFORM_VERSION="v0.8.0"
readonly KUBECONFORM_SHA256="9bc2bffbf71f261128533edaf912153948b7ff238f9a531ae6d34466ec287883"
readonly KUBE_LINTER_VERSION="v0.8.3"
readonly KUBE_LINTER_SHA256="1a6d8419b11971372971fdbc22682b684ebfb7cf1c39591662d1b6ca736c41df"
readonly KUSTOMIZE_VERSION="v5.8.3"
readonly KUSTOMIZE_SHA256="cb9e31198d3f63b44848bd0afc4c8efc56e6cfef9c93a4a39a211940e6decd61"
readonly HELM_UNITTEST_VERSION="v1.2.1"
# -----------------------------------------------------------------------------

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

# download <url> <sha256> <dest>
download() {
  local url="$1" sha="$2" dest="$3"
  curl -fsSL --retry 3 -o "${dest}" "${url}"
  echo "${sha}  ${dest}" | sha256sum --check --quiet -
}

# install_bin <name> <version> <url> <sha256> [path-inside-tar]
install_bin() {
  local name="$1" version="$2" url="$3" sha="$4" member="${5:-}"
  local stamp="${BIN_DIR}/.${name}-${version}"
  if [[ -f "${stamp}" && -x "${BIN_DIR}/${name}" ]]; then
    return 0
  fi
  log "instalando ${name} ${version}"
  local tmp
  tmp="$(mktemp -d)"
  download "${url}" "${sha}" "${tmp}/artifact"
  if [[ -n "${member}" ]]; then
    tar -xzf "${tmp}/artifact" -C "${tmp}" "${member}"
    install -m 0755 "${tmp}/${member}" "${BIN_DIR}/${name}"
  else
    install -m 0755 "${tmp}/artifact" "${BIN_DIR}/${name}"
  fi
  rm -rf "${tmp}" "${BIN_DIR}/.${name}-"*
  touch "${stamp}"
}

main() {
  if [[ "$(uname -s)-$(uname -m)" != "Linux-x86_64" ]]; then
    echo "Rode no WSL (Ubuntu x86_64) ou em um runner Linux." >&2
    exit 1
  fi
  mkdir -p "${BIN_DIR}"
  case ":${PATH}:" in
    *":${BIN_DIR}:"*) ;;
    *) echo "Adicione ${BIN_DIR} ao PATH (ex.: no ~/.bashrc)." >&2 ;;
  esac
  export PATH="${BIN_DIR}:${PATH}"

  log "pacotes apt"
  sudo apt-get update -qq
  sudo apt-get install -y -qq curl git jq make pipx python3 python3-venv openssh-client >/dev/null

  log "ferramentas Python (pipx)"
  pipx install --force "ansible-core==${ANSIBLE_CORE_VERSION}" >/dev/null
  pipx inject ansible-core "kubernetes==${KUBERNETES_PY_VERSION}" >/dev/null
  pipx install --force "ansible-lint==${ANSIBLE_LINT_VERSION}" >/dev/null
  pipx install --force "pre-commit==${PRE_COMMIT_VERSION}" >/dev/null

  install_bin sops "${SOPS_VERSION}" \
    "https://github.com/getsops/sops/releases/download/${SOPS_VERSION}/sops-${SOPS_VERSION}.linux.amd64" \
    "${SOPS_SHA256}"
  install_bin age "${AGE_VERSION}" \
    "https://github.com/FiloSottile/age/releases/download/${AGE_VERSION}/age-${AGE_VERSION}-linux-amd64.tar.gz" \
    "${AGE_SHA256}" age/age
  install_bin age-keygen "${AGE_VERSION}" \
    "https://github.com/FiloSottile/age/releases/download/${AGE_VERSION}/age-${AGE_VERSION}-linux-amd64.tar.gz" \
    "${AGE_SHA256}" age/age-keygen
  install_bin helm "${HELM_VERSION}" \
    "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" \
    "${HELM_SHA256}" linux-amd64/helm
  install_bin kubectl "${KUBECTL_VERSION}" \
    "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
    "${KUBECTL_SHA256}"
  install_bin kubeconform "${KUBECONFORM_VERSION}" \
    "https://github.com/yannh/kubeconform/releases/download/${KUBECONFORM_VERSION}/kubeconform-linux-amd64.tar.gz" \
    "${KUBECONFORM_SHA256}" kubeconform
  install_bin kube-linter "${KUBE_LINTER_VERSION}" \
    "https://github.com/stackrox/kube-linter/releases/download/${KUBE_LINTER_VERSION}/kube-linter-linux.tar.gz" \
    "${KUBE_LINTER_SHA256}" kube-linter
  install_bin kustomize "${KUSTOMIZE_VERSION}" \
    "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2F${KUSTOMIZE_VERSION}/kustomize_${KUSTOMIZE_VERSION}_linux_amd64.tar.gz" \
    "${KUSTOMIZE_SHA256}" kustomize

  if ! helm plugin list 2>/dev/null | grep -q "^unittest[[:space:]]\+${HELM_UNITTEST_VERSION#v}"; then
    log "helm-unittest ${HELM_UNITTEST_VERSION}"
    helm plugin uninstall unittest >/dev/null 2>&1 || true
    # Helm 4 verifica assinatura de plugins por padrão; o helm-unittest é instalado pela tag fixada.
    helm plugin install https://github.com/helm-unittest/helm-unittest --version "${HELM_UNITTEST_VERSION}" --verify=false
  fi

  log "coleções Ansible"
  ansible-galaxy collection install -r "${REPO_ROOT}/ansible/requirements.yml" >/dev/null

  log "pronto. Próximo passo: pre-commit install"
}

main "$@"
