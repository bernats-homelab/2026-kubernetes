#!/usr/bin/env bash
# fmt + validate dos diretórios OpenTofu sem token nem state: init sem backend, só
# com os providers do .terraform.lock.hcl (cache em .cache/tofu-plugins).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
export TF_PLUGIN_CACHE_DIR="${REPO_ROOT}/.cache/tofu-plugins"
# validate não lê o state, mas a config de criptografia exige a variável (pbkdf2: ≥ 16 caracteres).
export TF_VAR_state_passphrase="somente-para-o-validate"
mkdir -p "${TF_PLUGIN_CACHE_DIR}"

tofu fmt -check -recursive "${REPO_ROOT}/infra"
while read -r dir; do
  tofu -chdir="${dir}" init -backend=false -input=false -lockfile=readonly >/dev/null
  tofu -chdir="${dir}" validate -no-color
done < <(find "${REPO_ROOT}/infra" -name versions.tf -printf '%h\n' | sort)
