#!/usr/bin/env bash
# Vendoriza os dashboards da comunidade do Grafana, com versão fixada e sha256.
#
#   scripts/vendor-dashboards.sh            baixa, confere o sha256 do upstream, aplica
#                                           os patches e grava os JSONs
#   scripts/vendor-dashboards.sh --update   idem, mas regrava os hashes do lock
#                                           (use ao subir a versão de um dashboard)
#   scripts/vendor-dashboards.sh --check    offline: confere o que está versionado
#
# Lock: kubernetes/workloads/observability/base/dashboards/dashboards.lock
#   nome  pasta-do-grafana  url  sha256-upstream  sha256-saida
# Patches: .../dashboards/patches/<nome>.jq (jq, aplicados depois do filtro comum).
# Dashboards próprios (fora do lock) ficam em <pasta>/<nome>.json, escritos à mão.
# O kustomization.yaml do diretório (um ConfigMap por dashboard, com a pasta do
# Grafana na annotation grafana_folder) é gerado aqui.
# Licenças: os mixins da Grafana (Loki, Tempo) são AGPL-3.0; o restante vem dos
# autores citados no lock (grafana.com) e do repositório do ArgoCD (Apache-2.0).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIR="${ROOT}/kubernetes/workloads/observability/base/dashboards"
LOCK="${DIR}/dashboards.lock"
MODE="${1:-vendor}"
MAX_BYTES=$((900 * 1024))

# Filtro comum: sem __inputs/__requires, id nulo, uid estável, datasources por uid
# (as variáveis DS_* dos exports do grafana.com são removidas).
read -r -d '' COMMON <<'JQ' || true
def ds: if . == "${DS_LOKI}" then "loki" else "prometheus" end;
def isds: type == "string" and test("^\\$\\{DS_[A-Z_]+\\}$");
del(.__inputs, .__requires)
| .id = null
| .uid = $uid
| .tags = ((.tags // []) + ["community"] | unique)
| .templating.list |= map(select((.name | startswith("DS_")) | not))
| walk(
    if type == "object" and (.datasource? | isds)
    then .datasource = {type: (.datasource | ds), uid: (.datasource | ds)}
    elif type == "object" and (.uid? | isds)
    then if .type == "__expr__" then .uid = "__expr__" else .uid = (.uid | ds) end
    else . end)
JQ

transform() { # nome arquivo-bruto
  local name="$1" raw="$2" patch="${DIR}/patches/${1}.jq"
  local out
  out="$(jq -S --arg uid "$name" "$COMMON" "$raw")"
  if [[ -f "$patch" ]]; then
    out="$(jq -S -L "${DIR}/patches" -f "$patch" <<<"$out")"
  fi
  jq -cS . <<<"$out"
}

sha() { sha256sum "$1" | cut -d' ' -f1; }

# kustomization.yaml: um ConfigMap por dashboard (o last-applied do ArgoCD e o limite
# de 1 MiB do ConfigMap não se acumulam).
kustomization() {
  cat <<'YAML'
# GERADO por scripts/vendor-dashboards.sh: não edite.
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
generatorOptions:
  disableNameSuffixHash: true
configMapGenerator:
YAML
  local f folder name
  for f in "${DIR}"/*/*.json; do
    [[ "$f" == "${DIR}/patches/"* ]] && continue
    folder="$(basename "$(dirname "$f")")"
    name="$(basename "$f" .json)"
    cat <<YAML
  - name: grafana-dashboard-${name}
    files:
      - ${folder}/${name}.json
    options:
      labels:
        grafana_dashboard: "1"
      annotations:
        grafana_folder: ${folder}
YAML
  done
}

check() {
  local fail=0 uids f
  uids="$(mktemp)"
  trap 'rm -f "$uids"' RETURN
  while read -r name folder _url _up out; do
    [[ -z "$name" || "$name" == \#* ]] && continue
    f="${DIR}/${folder}/${name}.json"
    if [[ ! -f "$f" ]]; then
      echo "falta ${f#"$ROOT"/}"
      fail=1
      continue
    fi
    [[ "$(sha "$f")" == "$out" ]] || {
      echo "sha256 diferente do lock: ${name} (rode --update)"
      fail=1
    }
  done <"$LOCK"
  for f in "${DIR}"/*/*.json; do
    [[ "$f" == "${DIR}/patches/"* ]] && continue
    # shellcheck disable=SC2016
    if grep -qF '${DS_' "$f"; then
      echo "$(basename "$f"): sobrou \${DS_...}"
      fail=1
    fi
    [[ "$(wc -c <"$f")" -lt "$MAX_BYTES" ]] || {
      echo "$(basename "$f"): maior que 900 KiB"
      fail=1
    }
    jq -r '.uid' "$f" >>"$uids"
  done
  if [[ -n "$(sort "$uids" | uniq -d)" ]]; then
    echo "uids repetidos: $(sort "$uids" | uniq -d)"
    fail=1
  fi
  diff -q <(kustomization) "${DIR}/kustomization.yaml" >/dev/null ||
    {
      echo "kustomization.yaml desatualizado (rode o script)"
      fail=1
    }
  return "$fail"
}

vendor() {
  local update="$1" tmp new_lock name folder url up got
  tmp="$(mktemp -d)"
  new_lock="${tmp}/lock"
  trap 'rm -rf "$tmp"' RETURN
  while IFS= read -r line; do
    if [[ -z "$line" || "$line" == \#* ]]; then
      echo "$line" >>"$new_lock"
      continue
    fi
    read -r name folder url up _out <<<"$line"
    curl -fsSL --retry 3 -o "${tmp}/${name}.raw" "$url"
    got="$(sha "${tmp}/${name}.raw")"
    if [[ "$up" != "-" && "$got" != "$up" && "$update" != "1" ]]; then
      echo "ERRO: ${name}: o upstream mudou (esperado ${up}, veio ${got})" >&2
      return 1
    fi
    mkdir -p "${DIR}/${folder}"
    transform "$name" "${tmp}/${name}.raw" >"${DIR}/${folder}/${name}.json"
    printf '%s %s %s %s %s\n' "$name" "$folder" "$url" "$got" "$(sha "${DIR}/${folder}/${name}.json")" >>"$new_lock"
    echo "ok ${name} (${folder})"
  done <"$LOCK"
  kustomization >"${DIR}/kustomization.yaml"
  if [[ "$update" == "1" ]]; then cp "$new_lock" "$LOCK"; else
    diff -q <(grep -v '^#' "$LOCK") <(grep -v '^#' "$new_lock") >/dev/null ||
      {
        echo "ERRO: saída diferente do lock (patch mudou? rode --update)" >&2
        return 1
      }
    check
  fi
}

case "$MODE" in
  --check) check ;;
  --update) vendor 1 ;;
  vendor) vendor 0 ;;
  *)
    echo "uso: $0 [--update|--check]" >&2
    exit 2
    ;;
esac
