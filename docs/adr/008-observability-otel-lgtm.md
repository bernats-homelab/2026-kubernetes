# 008 — Observabilidade: OpenTelemetry Collector + LGTM enxuto

- **Status:** aceito
- **Data:** 2026-11-07

## Contexto

Queremos logs, métricas e traces do cluster, do próprio notebook, do NAS e, mais tarde, de outros bare metal. Há quatro requisitos:

- **Tudo em OpenTelemetry (OTLP).** Assim dá para experimentar outros backends sem reinstrumentar nada.
- **Projetos CNCF ou open source.**
- **Leveza e poucas peças.** O notebook tem 4 threads, 18 GB de RAM e ~37 GB de disco livre.
- **Alertas por e-mail.**

## Decisão

- **Coleta: OpenTelemetry Collector upstream (CNCF), imagem `otelcol-contrib`.**
  - `otel-agent` (DaemonSet): logs dos pods, kubelet, OTLP dos apps e scrape dos `/metrics` que já existem (ArgoCD, CNPG).
  - `otel-gateway` (Deployment): recebe tudo, coleta métricas e eventos do cluster e é o **único** lugar que conhece os backends. Fica exposto na tailnet como `otel`, que é a porta de entrada dos hosts e do NAS.
  - Hosts (notebook, bare metal): o role `otel_host_agent` instala o `.deb` (journald + métricas do host). A imagem do Collector não tem `journalctl`, então de dentro do cluster não se vê o journald.
  - NAS: um container pelo compose do OMV (`hosts/nas/otel-collector`), com fila só em memória por causa do pendrive. O Ansible não toca no NAS.
- **Backends: Prometheus (OTLP nativo), Loki, Tempo e Grafana**, cada um como binário único, em disco local (local-path).
  - O Mimir não compensa num nó só, e o Prometheus 3 já aceita OTLP.
  - Os backends não fazem scrape. Toda métrica entra por OTLP. A única exceção é o metrics-generator do Tempo, que só sabe fazer remote write.
- **Alertas pelo Grafana Alerting**, com SMTP do Gmail. As regras ficam versionadas e são carregadas por ConfigMap pelo sidecar. As credenciais e o destinatário ficam num Secret SOPS, só no overlay do notebook.
- **Retenção pelo disco:** métricas 30 d (ou 6 GB), logs 14 d e traces 7 d. São ~18 GiB de PVCs, e um alerta dispara se o disco raiz passar de 85%.

## Alternativas consideradas

| | Por que não (por ora) |
|---|---|
| **Victoria** (VictoriaMetrics + VictoriaLogs + VictoriaTraces) | É o mais leve e todo Apache-2.0, mas o VictoriaTraces ainda está em v0.x, com breaking changes recentes. Também concentra tudo num vendor só. |
| **OpenObserve** | Um binário só para tudo, mas fica fora do ecossistema Grafana, com consultas em SQL e licença AGPL. |
| **SigNoz / ClickStack** | O ClickHouse é pesado demais para o notebook. |
| **Stack 100% CNCF** (Prometheus + Jaeger v2 + Perses) | Não há armazenamento de logs na CNCF, e a correlação entre os sinais fica fragmentada. |
| **Grafana Alloy** | Ele roda o mesmo YAML do Collector (*OTel engine*), mas esse modo ainda está em Public Preview, e a sintaxe nativa (River) amarra a configuração ao Alloy. O Collector upstream mantém a troca barata. |

## Consequências

- **Trocar de backend = trocar os exporters do `otel-gateway`.** Agentes, hosts e NAS não mudam.
- **Disco local:** os dados morrem junto com o notebook, e a retenção é curta. Object storage (S3) fica para uma fase seguinte.
- **Nomes de métricas seguem a tradução OTLP→Prometheus** (`system.filesystem.usage` → `system_filesystem_usage_bytes`). `service.name` vira o label `job` no Prometheus e `service_name` no Loki. Os hosts usam `homelab-host` e o NAS usa `nas-host`, para não versionar hostnames.
- **No CI**, o Grafana sobe sem segredos (sem SMTP nem Ingress), e o e2e confere o fluxo completo: métricas, logs e um trace sintético (`telemetrygen`).
- **Os charts da Grafana migraram para `grafana-community`.** Os de `grafana/` estão deprecados.

## Dashboards e alertas da comunidade

Os dashboards e as regras de alerta vêm de projetos da comunidade, **sem** instalar kube-state-metrics, node-exporter nem cAdvisor: o stack continua só com as métricas OTel nativas (`kubeletstats`, `k8s_cluster`, `hostmetrics`).

- **Dashboards vendorizados e fixados.** `scripts/vendor-dashboards.sh` baixa cada dashboard de uma versão fixa (grafana.com por ID e revisão; ArgoCD, Loki e Tempo por tag), confere o sha256 do upstream no `dashboards.lock` e aplica um filtro comum (datasources por uid) mais um patch jq por dashboard (`patches/<nome>.jq`). Um `kustomization.yaml` gerado cria um ConfigMap por dashboard, com a pasta do Grafana na annotation `grafana_folder`. O `gnetId` do chart ficou de fora: ele baixa na subida do pod, sem hash e sem patch.
- **Patches típicos.** O `job` vem como `service.namespace/service.name`; contadores chegam com o sufixo `_total`; as recording rules dos mixins não existem; e os painéis que dependem de `kube_*`, de `kubelet_volume_stats_*` (o `local-path` não os reporta) ou do controller-runtime do operador do CNPG são removidos.
- **Dois dashboards próprios** (cluster e Immich), porque nenhum da comunidade usa as métricas `k8s_cluster` nem as do Immich atual.
- **Alertas convertidos para o Grafana**, não para o Prometheus: um caminho só até o e-mail, sem Alertmanager. Cada regra cita a origem (kubernetes-mixin, awesome-prometheus-alerts, regras do CloudNativePG) e foi reescrita para nossos nomes. O conjunto é curado para um nó único: ficaram de fora HA, réplicas, lag, disco de PVC e backups.
- **Scrapes novos, todos por OTLP.** O `otel-agent` passou a raspar Loki, Tempo, Prometheus e CoreDNS (com allowlist de séries e `cluster=homelab`) e a mandar a própria telemetria dos coletores. Isso deixa de fora, por ora, o Grafana e o Tailscale: os proxies precisam de um `ProxyClass` com métricas, e fica para uma próxima etapa.
- **Rotas por `severity`:** `critical` e `warning` chegam por e-mail; `info` só aparece na UI.
- **Verificação.** `make test` confere o lock (`--check`) e as regras (`scripts/check-alert-rules.py`); o e2e confere que o sidecar do Grafana carregou todos os arquivos. `scripts/check-dashboard-metrics.py` roda à mão contra o Prometheus do notebook e lista as métricas que faltam.
