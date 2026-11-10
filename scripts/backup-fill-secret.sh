#!/usr/bin/env bash
# Depois do `make tofu-apply`: grava no Secret do restic (SOPS) o RESTIC_REPOSITORY e
# o known_hosts do Storage Box. Rode pelo `make backup-secret`, que exporta o token e
# a passphrase do state. O usuário e o FQDN do box só existem no state criptografado.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly TOFU_DIR="${REPO_ROOT}/infra/hetzner"
readonly SECRET="${REPO_ROOT}/kubernetes/workloads/backup/overlays/nas/restic.sops.yaml"
readonly SSH_PORT=23

tofu -chdir="${TOFU_DIR}" init -input=false -lockfile=readonly >/dev/null
user="$(tofu -chdir="${TOFU_DIR}" output -raw storage_box_username)"
server="$(tofu -chdir="${TOFU_DIR}" output -raw storage_box_server)"

# Confira a impressão digital no painel da Hetzner (Storage Box > SSH) se desconfiar.
known_hosts="$(ssh-keyscan -p "${SSH_PORT}" -t ed25519,rsa "${server}" 2>/dev/null)"
if [[ -z "${known_hosts}" ]]; then
  echo "ERRO: ssh-keyscan não respondeu em ${server}:${SSH_PORT}" >&2
  exit 1
fi

# Caminho relativo ao home do box: o repositório fica em ~/restic.
repository="sftp://${user}@${server}:${SSH_PORT}/restic"

sops set "${SECRET}" '["stringData"]["RESTIC_REPOSITORY"]' "$(jq -Rn --arg v "${repository}" '$v')"
sops set "${SECRET}" '["stringData"]["known_hosts"]' "$(jq -Rn --arg v "${known_hosts}" '$v')"
echo "OK: ${SECRET#"${REPO_ROOT}"/} atualizado. Revise com 'sops ${SECRET#"${REPO_ROOT}"/}' e commite."
