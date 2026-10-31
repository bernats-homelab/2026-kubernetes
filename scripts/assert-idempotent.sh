#!/usr/bin/env bash
# Roda ansible-playbook com os argumentos dados e falha se alguma task reportar mudança.
# Uso: scripts/assert-idempotent.sh site.yaml [args do ansible-playbook...]
set -euo pipefail

log="$(mktemp)"
trap 'rm -f "${log}"' EXIT

ansible-playbook "$@" | tee "${log}"

# Remove cores ANSI (ANSIBLE_FORCE_COLOR) e fica só com as linhas do PLAY RECAP
recap="$(sed -E 's/\x1b\[[0-9;]*m//g' "${log}" | grep -E '^[^ ]+[[:space:]]+: ok=' || true)"

if [[ -z "${recap}" ]]; then
  echo "ERRO: PLAY RECAP não encontrado na saída." >&2
  exit 1
fi
if grep -qvE 'changed=0[[:space:]]' <<<"${recap}"; then
  echo "ERRO: playbook não é idempotente (changed > 0 na segunda execução)." >&2
  exit 1
fi
echo "OK: segunda execução sem mudanças."
