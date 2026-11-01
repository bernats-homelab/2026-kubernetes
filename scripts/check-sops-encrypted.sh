#!/usr/bin/env bash
# Falha se algum *.sops.yaml não estiver criptografado pelo SOPS:
#   - precisa ter o bloco de metadados `sops:` com `mac: ENC[...]`
#   - todo valor escalar fora do bloco `sops:` precisa ser `ENC[...]`, exceto as chaves
#     de topo liberadas pelo `unencrypted_regex` do próprio arquivo (manifests do KSOPS)
#   - precisa ter pelo menos um valor `ENC[...]`
#   - a chave de teste do CI (pública, tests/ci-age.key) só pode ser destinatária
#     dos arquivos de demonstração em kubernetes/workloads/hello-world/
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly CI_DEMO_PATH='(^|/)kubernetes/workloads/hello-world/'
CI_RECIPIENT="$(sed -nE 's/^# public key: (age1[0-9a-z]+)$/\1/p' "${REPO_ROOT}/tests/ci-age.key")"
readonly CI_RECIPIENT

status=0
for file in "$@"; do
  if ! grep -qE '^sops:' "${file}" || ! grep -qE '^[[:space:]]+mac: ENC\[' "${file}"; then
    echo "ERRO: ${file} não tem metadados SOPS (sops/mac). Rode: sops encrypt --in-place ${file}" >&2
    status=1
    continue
  fi
  if grep -qE '^[[:space:]]+encrypted_regex:' "${file}"; then
    echo "ERRO: ${file} usa encrypted_regex; use unencrypted_regex (regras em .sops.yaml)" >&2
    status=1
    continue
  fi
  if [[ -n "${CI_RECIPIENT}" ]] && grep -qF "recipient: ${CI_RECIPIENT}" "${file}" && ! [[ "${file}" =~ ${CI_DEMO_PATH} ]]; then
    echo "ERRO: ${file} está criptografado para a chave PÚBLICA de teste do CI (tests/ci-age.key)." >&2
    echo "      Ela só é permitida em kubernetes/workloads/hello-world/. Rode: sops updatekeys ${file}" >&2
    status=1
    continue
  fi
  unencrypted="$(sed -nE 's/^[[:space:]]+unencrypted_regex: (.*)$/\1/p' "${file}")"
  plaintext="$(awk -v unencrypted="${unencrypted}" '
    /^sops:/ { in_sops = 1; next }
    /^[^[:space:]#]/ {
      in_sops = 0
      top = $0; sub(/:.*/, "", top)
      skip = (unencrypted != "" && top ~ unencrypted)
    }
    in_sops || skip { next }
    /^[[:space:]]*(#|$)/ { next }
    /^[[:space:]]*-?[[:space:]]*[^:]+:[[:space:]]*$/ { next }
    /:[[:space:]]+ENC\[/ { encrypted++; next }
    /^[[:space:]]*-[[:space:]]+ENC\[/ { encrypted++; next }
    { print FILENAME ":" NR }
    END { if (!encrypted) print FILENAME ":sem-valores-criptografados" }
  ' "${file}")"
  if [[ -n "${plaintext}" ]]; then
    echo "ERRO: valores em texto claro em ${file} (linhas: ${plaintext//$'\n'/, })" >&2
    status=1
  fi
done
exit "${status}"
