#!/usr/bin/env bash
# Roda ansible-playbook com os argumentos dados e falha se alguma task reportar mudança.
# Uso: scripts/assert-idempotent.sh site.yaml [args do ansible-playbook...]
set -euo pipefail

log="$(mktemp)"
trap 'rm -f "${log}"' EXIT

ansible-playbook "$@" | tee "${log}"

if ! grep -qE '^[^ ]+[[:space:]]+: ok=' "${log}"; then
  echo "ERRO: PLAY RECAP não encontrado na saída." >&2
  exit 1
fi
if grep -E '^[^ ]+[[:space:]]+: ok=' "${log}" | grep -qvE 'changed=0[[:space:]]'; then
  echo "ERRO: playbook não é idempotente (changed > 0 na segunda execução)." >&2
  exit 1
fi
echo "OK: segunda execução sem mudanças."
