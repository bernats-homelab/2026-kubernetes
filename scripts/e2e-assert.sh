#!/usr/bin/env bash
# Asserções do e2e (CI) contra o k3s local do runner.
set -euo pipefail

kubectl() { sudo /usr/local/bin/k3s kubectl "$@"; }

echo "==> node Ready"
kubectl wait --for=condition=Ready node --all --timeout=300s

for app in root argocd hello-world cloudnative-pg immich-database immich obsidian home-assistant-database home-assistant backup k8s-app-smoke grocery-ops prometheus loki tempo observability otel-gateway otel-agent grafana; do
  echo "==> Application ${app} Synced + Healthy"
  kubectl -n argocd wait "application/${app}" --for=create --timeout=300s
  kubectl -n argocd wait "application/${app}" --for=jsonpath='{.status.sync.status}'=Synced --timeout=600s
  kubectl -n argocd wait "application/${app}" --for=jsonpath='{.status.health.status}'=Healthy --timeout=600s
done

echo "==> Tailscale Operator ausente no CI"
if kubectl -n argocd get application/tailscale-operator >/dev/null 2>&1; then
  echo "ERRO: tailscale-operator não deveria existir com tailscaleOperator.enabled=false" >&2
  exit 1
fi

echo "==> hello-world responde via Service"
kubectl -n hello-world rollout status deployment/hello-world --timeout=300s
body="$(kubectl get --raw /api/v1/namespaces/hello-world/services/hello-world:http/proxy/)"
grep -q '^Hostname: hello-world-' <<<"${body}" || {
  echo "ERRO: resposta inesperada do hello-world:" >&2
  echo "${body}" >&2
  exit 1
}
echo "==> KSOPS: Secret do demo descriptografado pelo ArgoCD"
message="$(kubectl -n hello-world get secret hello-world-demo -o jsonpath='{.data.message}' | base64 -d)"
if [[ "${message}" != "olá do KSOPS" ]]; then
  echo "ERRO: hello-world-demo.message inesperado: '${message}'" >&2
  exit 1
fi
echo "==> Postgres do Immich (CNPG) pronto com as extensões"
kubectl -n immich wait cluster.postgresql.cnpg.io/immich-database --for=condition=Ready --timeout=600s
kubectl -n immich wait database.postgresql.cnpg.io/immich-database --for=jsonpath='{.status.applied}'=true --timeout=300s

echo "==> Immich responde /api/server/ping"
kubectl -n immich rollout status deployment/immich-server --timeout=600s
ping="$(kubectl get --raw /api/v1/namespaces/immich/services/immich-server:http/proxy/api/server/ping)"
grep -q '"res":"pong"' <<<"${ping}" || {
  echo "ERRO: resposta inesperada do Immich: ${ping}" >&2
  exit 1
}

echo "==> Obsidian (Selkies) serve a página web"
kubectl -n obsidian rollout status deployment/obsidian --timeout=600s
page="$(kubectl get --raw /api/v1/namespaces/obsidian/services/obsidian:http/proxy/)"
grep -qi '<html' <<<"${page}" || {
  echo "ERRO: resposta inesperada do Obsidian:" >&2
  head -c 500 <<<"${page}" >&2
  exit 1
}

echo "==> Postgres do Home Assistant (CNPG) pronto"
kubectl -n home-assistant wait cluster.postgresql.cnpg.io/home-assistant-database --for=condition=Ready --timeout=600s

echo "==> Home Assistant serve /manifest.json"
kubectl -n home-assistant rollout status deployment/home-assistant --timeout=900s
# De dentro do pod: o proxy da API adiciona X-Forwarded-For, e o HA responde 400 a
# proxies não confiáveis (a confiança é configurada pela UI, veja o ADR 009).
manifest="$(kubectl -n home-assistant exec deployment/home-assistant -c home-assistant -- \
  python3 -c 'import urllib.request; print(urllib.request.urlopen("http://127.0.0.1:8123/manifest.json").read().decode())')"
grep -q "Home Assistant" <<<"${manifest}" || {
  echo "ERRO: resposta inesperada do Home Assistant:" >&2
  head -c 500 <<<"${manifest}" >&2
  exit 1
}

echo "==> Backup: o script do restic roda ponta a ponta (repositório local no CI)"
kubectl -n backup delete job e2e-backup --ignore-not-found
kubectl -n backup create job e2e-backup --from=cronjob/restic-backup
kubectl -n backup wait job/e2e-backup --for=condition=Complete --timeout=600s
backup_log="$(kubectl -n backup logs job/e2e-backup)"
grep -q '"message_type":"summary"' <<<"${backup_log}" || {
  echo "ERRO: o restic não logou o summary do backup:" >&2
  echo "${backup_log}" >&2
  exit 1
}

echo "==> App externa (repotpl-k8s-app) no AppProject homelab-apps responde /healthz"
project="$(kubectl -n argocd get application/k8s-app-smoke -o jsonpath='{.spec.project}')"
if [[ "${project}" != "homelab-apps" ]]; then
  echo "ERRO: k8s-app-smoke está no project '${project}', esperado homelab-apps" >&2
  exit 1
fi
kubectl -n k8s-app-smoke rollout status deployment/app-template --timeout=300s
health="$(kubectl get --raw /api/v1/namespaces/k8s-app-smoke/services/app-template:http/proxy/healthz)"
if [[ "${health}" != "ok" ]]; then
  echo "ERRO: resposta inesperada da app externa: '${health}'" >&2
  exit 1
fi

echo "==> grocery-ops (Bemesko/grocery-ops, Nuxt) responde /healthz"
kubectl -n grocery-ops rollout status deployment/grocery-ops --timeout=300s
health="$(kubectl get --raw /api/v1/namespaces/grocery-ops/services/grocery-ops:http/proxy/healthz)"
if [[ "${health}" != "ok" ]]; then
  echo "ERRO: resposta inesperada do grocery-ops: '${health}'" >&2
  exit 1
fi

echo "==> Observabilidade: Grafana responde /api/health"
kubectl -n observability rollout status deployment/grafana --timeout=600s
grafana="$(kubectl get --raw /api/v1/namespaces/observability/services/grafana:80/proxy/api/health)"
grep -q '"database": *"ok"' <<<"${grafana}" || {
  echo "ERRO: resposta inesperada do Grafana: ${grafana}" >&2
  exit 1
}

# retry <descrição> <comando...>: o pipeline (agent -> gateway -> backend) leva alguns minutos.
retry() {
  local what="$1" _
  shift
  for _ in $(seq 1 30); do
    if "$@"; then return 0; fi
    sleep 10
  done
  echo "ERRO: ${what} não apareceu em 5 min" >&2
  return 1
}

prom_has_kubelet_metrics() {
  kubectl get --raw '/api/v1/namespaces/observability/services/prometheus-server:80/proxy/api/v1/query?query=count(%7B__name__%3D~%22k8s_pod_.%2A%22%7D)' |
    grep -q '"result":\[{'
}
echo "==> Observabilidade: métricas do kubelet chegaram ao Prometheus por OTLP"
retry "métricas k8s_pod_* no Prometheus" prom_has_kubelet_metrics

loki_has_argocd_logs() {
  kubectl get --raw '/api/v1/namespaces/observability/services/loki:3100/proxy/loki/api/v1/query?query=count_over_time(%7Bk8s_namespace_name%3D%22argocd%22%7D%5B10m%5D)' |
    grep -q '"result":\[{'
}
echo "==> Observabilidade: logs dos pods do ArgoCD chegaram ao Loki por OTLP"
retry "logs do namespace argocd no Loki" loki_has_argocd_logs

echo "==> Observabilidade: trace sintético (telemetrygen -> otel-agent -> gateway -> Tempo)"
kubectl -n observability delete job e2e-telemetrygen --ignore-not-found
kubectl -n observability create job e2e-telemetrygen \
  --image=ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:v0.163.0@sha256:569b79a39f8313db839a727e8eac161c66b8a6c2e633f2da4ad352ce7b383c23 \
  -- /telemetrygen traces --otlp-endpoint=otel-agent.observability.svc:4317 --otlp-insecure --traces=5 --service=e2e-telemetrygen
kubectl -n observability wait job/e2e-telemetrygen --for=condition=Complete --timeout=300s
tempo_has_trace() {
  kubectl get --raw '/api/v1/namespaces/observability/services/tempo:3200/proxy/api/search?tags=service.name%3De2e-telemetrygen' |
    grep -q '"traceID"'
}
retry "trace do e2e-telemetrygen no Tempo" tempo_has_trace

echo "==> Observabilidade: o sidecar do Grafana carregou todos os dashboards e regras de alerta"
# Os arquivos esperados vêm do próprio repo (dashboards da comunidade + próprios, e as
# regras em alerts/). O sidecar escreve cada ConfigMap no volume do Grafana.
expected_dashboards="$(find kubernetes/workloads/observability/base/dashboards -mindepth 2 -name '*.json' -not -path '*/patches/*' | wc -l)"
expected_alert_files="$(find kubernetes/workloads/observability/base/alerts -name '*.yaml' | wc -l)"
sidecar_loaded_everything() {
  local dashboards alerts
  dashboards="$(kubectl -n observability exec deploy/grafana -c grafana-sc-dashboard -- find /tmp/dashboards -name '*.json' | wc -l)"
  alerts="$(kubectl -n observability exec deploy/grafana -c grafana-sc-alerts -- ls /etc/grafana/provisioning/alerting | grep -c 'yaml')"
  [[ "${dashboards}" -ge "${expected_dashboards}" && "${alerts}" -ge "${expected_alert_files}" ]]
}
retry "${expected_dashboards} dashboards e ${expected_alert_files} arquivos de alerta no sidecar" sidecar_loaded_everything

echo "OK: e2e passou."
