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
