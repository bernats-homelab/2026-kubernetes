# 009 — Home Assistant no cluster, ponte da lista de compras da Alexa

- **Status:** aceito
- **Data:** 2026-11-08

## Contexto

Queremos que itens falados para a Alexa ("Alexa, coloca leite na lista de compras") cheguem ao grocery-ops (`Bemesko/grocery-ops`). A Amazon não tem API pública de listas para terceiros. Desde o Home Assistant 2026.7, a integração nativa **Alexa Devices** expõe as listas da Alexa como entidades `todo`, atualizadas por eventos push da Amazon (IoT class *Cloud Polling*). O HA vira a ponte, sem precisar ser exposto à internet.

## Decisão

- **Kustomize próprio** em `kubernetes/workloads/home-assistant`, como o Obsidian (ADR 006). Não existe chart oficial, e os da comunidade economizariam só uns 5 manifestos.
- **Imagem oficial** `ghcr.io/home-assistant/home-assistant` fixada por tag + digest.
- **`configuration.yaml` no Git** (ConfigMap montado por `subPath`). O resto do `/config` (`.storage`: integrações, usuários, tokens) fica numa PVC no **NAS por NFS**, via role `nas_storage`, e entra na réplica do NAS.
- **Recorder no Postgres** (CloudNativePG, Application `home-assistant-database`, wave 2). O HA lê a URI do Secret gerado pelo CNPG com `!env_var DB_URL`.
- **Só no notebook (overlay `tailscale`)**:
  - `hostNetwork`, para a descoberta mDNS/SSDP na LAN. O pod só escuta na rede do host, sem alterar rede, firewall ou SSH. Efeito colateral: o HA também responde em `<IP do notebook>:8123` na LAN.
  - `/run/dbus` do host, somente leitura, e as capabilities `NET_ADMIN`/`NET_RAW`, para usar o Bluetooth do notebook pelo BlueZ do host. Sem `privileged`.
  - Ingress `https://casa.<sua-tailnet>`.
- O CI usa o `base`: rede normal de pod, sem Bluetooth e sem Ingress.

## Contrato com o grocery-ops

O grocery-ops ainda não implementa a integração. A infra deixa pronto:

- **Rota interna:** `http://home-assistant.home-assistant.svc:8123`. Não há NetworkPolicy no cluster. Com `hostNetwork`, o endpoint do Service vira `<IP do nó>:8123` e continua funcionando.
- **Autenticação:** um usuário `grocery-ops` no HA com um *long-lived access token*. O token fica num `*.sops.yaml` no `deploy/` do repo do grocery-ops, não aqui.
- **Leitura:** `POST /api/services/todo/get_items?return_response` com `{"entity_id": "todo.<lista>", "status": "needs_action"}`, ou o comando de websocket equivalente.
- **Escrita:** `todo.add_item`, `todo.update_item` (marcar como comprado) e `todo.remove_item`.
- **Push HA → app (quando houver endpoint):** automação com os gatilhos `todo.item_added`, `todo.item_completed` e `todo.item_removed` chamando um `rest_command` para `http://grocery-ops.grocery-ops.svc/...`.

## Consequências e riscos

- A integração Alexa Devices exige 2FA por app autenticador na conta Amazon (SMS não serve). O suporte a amazon.com.br não está documentado; se não funcionar, a alternativa é a integração HACS `ocean90/alexa_shopping_sync`.
- O perfil AppArmor customizado do containerd (role `base`) não tem regras de `dbus`. Se o BlueZ negar o acesso, o perfil precisa de uma regra estreita para o barramento do sistema.
- Métricas do HA (`/api/prometheus`) ficam para depois: exigem um token criado na UI e montado no otel-agent. Os logs já chegam ao Loki pelo coletor.
- Não há backup do Postgres do HA além do disco do notebook. O histórico é descartável; o que importa (integrações, automações) fica no `/config` do NAS.
