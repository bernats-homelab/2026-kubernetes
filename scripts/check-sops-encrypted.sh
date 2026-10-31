#!/usr/bin/env bash
# Falha se algum *.sops.yaml não estiver criptografado pelo SOPS:
#   - precisa ter o bloco de metadados `sops:` com `mac: ENC[...]`
#   - todo valor escalar fora do bloco `sops:` precisa ser `ENC[...]`
set -euo pipefail

status=0
for file in "$@"; do
  if ! grep -qE '^sops:' "${file}" || ! grep -qE '^[[:space:]]+mac: ENC\[' "${file}"; then
    echo "ERRO: ${file} não tem metadados SOPS (sops/mac). Rode: sops --encrypt --in-place ${file}" >&2
    status=1
    continue
  fi
  plaintext="$(awk '
    /^sops:/ { in_sops = 1; next }
    /^[^[:space:]#]/ { in_sops = 0 }
    in_sops { next }
    /^[[:space:]]*(#|$)/ { next }
    /^[[:space:]]*-?[[:space:]]*[^:]+:[[:space:]]*$/ { next }
    /:[[:space:]]+ENC\[/ { next }
    /^[[:space:]]*-[[:space:]]+ENC\[/ { next }
    { print FILENAME ":" NR }
  ' "${file}")"
  if [[ -n "${plaintext}" ]]; then
    echo "ERRO: valores em texto claro em ${file} (linhas: ${plaintext//$'\n'/, })" >&2
    status=1
  fi
done
exit "${status}"
