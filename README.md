# 2026-kubernetes

Bootstrap e configuração de um cluster **k3s single-node** no notebook pessoal (Ubuntu 26.04).
Tudo é aplicado **remotamente**: o Ansible roda no WSL desta máquina e conecta no notebook por SSH pela tailnet.

```
WSL (controle)  ──ssh via Tailscale──▶  notebook (Ubuntu 26.04)
  ansible + sops/age                      k3s
                                           └─ ArgoCD (app-of-apps, GitOps deste repo)
                                               ├─ tailscale-operator  → Ingress na tailnet
                                               ├─ argocd (self-managed) → https://argocd.<sua-tailnet>
                                               ├─ hello-world           → https://hello.<sua-tailnet>
                                               ├─ cloudnative-pg        → Postgres do Immich
                                               ├─ immich                → https://fotos.<sua-tailnet>
                                               │    └─ NFS (tailnet) ──▶ NAS openmediavault (fotos ro, immich-data rw)
                                               ├─ home-assistant        → https://casa.<sua-tailnet> (/config no NAS, recorder no CNPG)
                                               └─ apps: (outros repos da org/Bemesko, AppProject homelab-apps)
                                                    └─ bernats-homelab/<app> @ vX.Y.Z → deploy/ → https://<app>.<sua-tailnet>
```

## Garantias de segurança

- **Sem lockout.** O playbook nunca mexe no Tailscale, no SSH, no firewall ou na rede do host. O role `tailscale_check` só lê o status, e o hook `no-lockout` barra qualquer task que tente alterar essas coisas.
- **Nada identificável no repo.** O inventário real fica em `ansible/inventory/local.yaml` (ignorado pelo git e barrado por hook). O nome da tailnet (`*.ts.net`) é descoberto em runtime e barrado pelo gitleaks. Os kubeconfigs ficam em `~/.kube/`.
- **Segredos com SOPS + age.** A chave privada fica só no WSL. O Ansible descriptografa no controller e cria os Secrets do bootstrap com `no_log` (veja [ADR 002](docs/adr/002-sops-age-secrets.md)). Os segredos dos apps são commitados criptografados ao lado do app, e o ArgoCD os descriptografa com KSOPS usando uma chave age própria do cluster (veja [ADR 004](docs/adr/004-ksops.md)).
- **Tampa fechada na energia não suspende.** O role `power` configura o `systemd-logind` (`HandleLidSwitchExternalPower=ignore` e `HandleLidSwitchDocked=ignore`) e confere via D-Bus que o valor efetivo foi aplicado. Na bateria continua valendo o padrão do sistema (suspender).
- **Atualizações do Ubuntu sem surpresa.** O role `os_updates` roda o unattended-upgrades às 05:15, com prioridade idle de CPU e I/O, e tira o kernel (`linux-*`) do automático: kernel só com `make kernel-upgrade`, que reinicia e valida o cluster. Veja o [ADR 010](docs/adr/010-notebook-os-updates.md).
- **Versões fixadas com sha256** para k3s (instalador), helm, kubectl, sops, age, kubeconform, kube-linter e kustomize. A imagem do hello-world é fixada por digest.
- **Uma fonte por versão.** As versões dos charts ficam só em [kubernetes/apps/values.yaml](kubernetes/apps/values.yaml), que o Ansible também lê no bootstrap.

## Pré-requisitos (uma vez)

### 1. WSL nesta máquina

```bash
make deps                 # ferramentas com versão/sha256 fixados em ~/.local/bin + coleções Ansible
pre-commit install
```

O repo pode ficar em `/mnt/c/dev/bernats-homelab/2026-kubernetes`. O `Makefile` exporta `ANSIBLE_CONFIG`, porque em `/mnt/c` o Ansible ignora o `ansible.cfg` do diretório world-writable. Faça os commits **pelo WSL** para os hooks rodarem; se algum escapar, o job `lint` do CI roda os mesmos hooks.

### 2. Acesso SSH ao notebook

```bash
ssh-copy-id <usuario>@<hostname-magicdns>
cp ansible/inventory/inventory.example.yaml ansible/inventory/local.yaml   # e preencha
```

### 3. Chave age

```bash
age-keygen -o ~/.config/sops/age/keys.txt
age-keygen -y ~/.config/sops/age/keys.txt   # chave pública → substitua em .sops.yaml
```

Guarde `keys.txt` no gerenciador de senhas. Sem esse arquivo não dá para descriptografar os segredos.

### 4. Tailscale (admin console)

1. Na policy, em `tagOwners`, adicione:
   ```json
   "tag:k8s-operator": ["autogroup:admin"],
   "tag:k8s": ["tag:k8s-operator"]
   ```
2. Em Trust credentials, crie um **OAuth client** com os scopes *Devices Core* e *Auth Keys* (write) e a tag `tag:k8s-operator`.
3. Em DNS, deixe **MagicDNS** e **HTTPS Certificates** habilitados.

### 5. Segredos

```bash
cp ansible/secrets/secrets.example.yaml ansible/secrets/secrets.sops.yaml
sops ansible/secrets/secrets.sops.yaml   # preencha client id/secret do OAuth client
```

Se o arquivo já existir em texto claro, criptografe com `sops --encrypt --in-place ...`. O hook `sops-encrypted` impede o commit de um arquivo descriptografado.

Preencha também `sops_age_cluster_key` com a chave privada age do cluster, que o KSOPS usa. Gere com `age-keygen` e coloque a chave pública correspondente no `.sops.yaml`, na regra de `kubernetes/`.

## Immich (fotos do NAS)

O Immich exibe, **somente leitura**, as fotos e vídeos do NAS como External Library. Os dados que ele gera (thumbnails, previews, transcodes e dumps diários do banco) ficam numa pasta própria no NAS. O Postgres fica no disco do notebook. Veja o [ADR 005](docs/adr/005-immich-nas-nfs.md).

### 1. NAS: exports NFS no OMV (uma vez, pela UI do openmediavault)

O playbook **nunca** altera o NAS; ele só confere o que você configurou aqui.

1. **Services → NFS → Settings**: marque *Enabled*, clique em *Save* e aplique as mudanças (banner amarelo).
2. **Storage → Shared Folders**: crie a pasta `immich-data` no disco com espaço (o Immich vai gravar de ~12 a 70 GB nela). A pasta das fotos já deve existir. Se as fotos estão espalhadas pelo disco, ela pode ser a shared folder da raiz do disco; nesse caso, veja os import paths no passo 3.
3. Descubra o UID/GID do dono dos arquivos, para o squash. Por exemplo, em **Users → Users** veja o UID do seu usuário (normalmente `1000`); o grupo `users` do OMV é o GID `100`.
4. **Services → NFS → Shares → Create**, duas vezes:

   | Shared folder | Client | Permission | Extra options |
   |---|---|---|---|
   | (pasta das fotos) | `<IP Tailscale do notebook>/32` | Read-only | `subtree_check,all_squash,anonuid=<uid>,anongid=<gid>` |
   | `immich-data` | `<IP Tailscale do notebook>/32` | Read/Write | `subtree_check,all_squash,anonuid=<uid>,anongid=<gid>` |

   Para descobrir o IP Tailscale do notebook, rode `tailscale ip -4` nele. O `all_squash` faz o Immich (que roda como root no container) gravar como o seu usuário.
5. Aplique as mudanças. Os exports aparecem como `/export/<pasta>`.

### 2. Inventário (`ansible/inventory/local.yaml`)

Preencha as variáveis de `inventory.example.yaml`: `nas_storage_enabled: true`, `nas_storage_host` e `nas_storage_exports.{photos,data,obsidian,home_assistant}`, que são os paths `/export/...` (o `obsidian` e o `home_assistant` estão descritos nas seções de cada app). Faça isso **antes** do primeiro `make apply` com o Immich. As PVCs são imutáveis, e com `nas_storage_enabled: false` elas seriam criadas em `local-path`.

Depois rode `make plan` e `make apply`. O role `nas_storage` confere os exports com `showmount` e faz uma montagem de teste de cada um, incluindo uma escrita em `immich-data`. Se algo estiver errado no OMV, ele falha antes de criar os PVs.

### 3. Primeiro acesso

1. Abra `https://fotos.<sua-tailnet>` e crie o usuário admin.
2. Em **Administration → External Libraries → Create**, adicione o import path `/mnt/nas/fotos` e clique em *Scan*.
   - Se o export de fotos for a raiz do disco, use um import path por subpasta (ex.: `/mnt/nas/fotos/<pasta>`) em vez de `/mnt/nas/fotos`. Assim a própria `immich-data`, que também está no disco, fica de fora; senão o Immich indexaria os thumbnails que ele mesmo gera.
   - Use *Exclusion patterns* para pular o que não é foto, como backups de sistema (ex.: `**/*backup-windows*/**`, `**/lost+found/**`).
   - As bibliotecas ficam no banco, não no `immich.configuration`, então são ajustadas pela UI.

As configurações do servidor vêm de `kubernetes/values/immich.yaml` (`immich.configuration`), e as telas de ajuste da UI ficam somente leitura. Para mudar algo (ligar o ML, o horário do scan), altere o arquivo e faça push.

### Backup e restauração do banco

O Immich faz um `pg_dump` diário em `immich-data/backups` no NAS e mantém 14 cópias. Para restaurar num cluster recriado:
```bash
gunzip -c <dump>.sql.gz | kubectl -n immich exec -i immich-database-1 -- psql -U postgres -d postgres
```
O dump é um `pg_dumpall` e já recria o banco `app`. Rode isso com o `immich-server` parado (`kubectl -n immich scale deploy/immich-server --replicas=0`). Depois volte o `replicas` para 1. O procedimento completo está na documentação do Immich, em *Backup and Restore*.

## Obsidian no navegador (vault do NAS)

O Obsidian desktop roda no cluster ([linuxserver/obsidian](https://docs.linuxserver.io/images/docker-obsidian/)) e abre pelo navegador em `https://borbsidian.<sua-tailnet>`, com usuário e senha. O vault fica no NAS, montado por NFS, e o estado do app (`/config`) fica no disco do notebook. Veja o [ADR 006](docs/adr/006-obsidian-nas-nfs.md).

1. **NAS (UI do OMV):** crie a shared folder do vault (pode apontar para a pasta que já existe) e um share NFS **Read/Write** para `<IP Tailscale do notebook>/32` com `subtree_check,all_squash,anonuid=<uid>,anongid=<gid>`, como o `immich-data`. Coloque o path em `nas_storage_exports.obsidian` e rode `make apply`.
2. **Senha:** o usuário e a senha estão em `kubernetes/workloads/obsidian/overlays/tailscale/auth.sops.yaml`:
   ```bash
   sops -d kubernetes/workloads/obsidian/overlays/tailscale/auth.sops.yaml
   ```
   Para trocar a senha, use `sops edit` no mesmo arquivo e faça push.
3. **Primeiro acesso:** no Obsidian, use *Open folder as vault* em `/vaults/borbsidian`. A escolha fica salva em `/config`.

**Edição em vários lugares.** Por NFS, o Obsidian do cluster não é avisado de mudanças feitas por outros dispositivos (Syncthing, SMB), porque o inotify não atravessa NFS. Edite num lugar por vez. Ao voltar para o Obsidian do navegador, use *Reload app without saving* (paleta de comandos) antes de editar, para não sobrescrever a versão mais nova.

## Home Assistant (ponte da lista de compras da Alexa)

O Home Assistant roda no cluster e abre em `https://casa.<sua-tailnet>`. O `configuration.yaml` vem do Git ([kubernetes/workloads/home-assistant/base/configuration.yaml](kubernetes/workloads/home-assistant/base/configuration.yaml)); o resto do `/config` fica no NAS e o histórico no Postgres (CNPG). No notebook ele usa `hostNetwork` (descoberta na LAN; também responde em `<IP do notebook>:8123`) e o Bluetooth do host via D-Bus. Veja o [ADR 009](docs/adr/009-home-assistant.md).

1. **NAS (UI do OMV):** crie a shared folder `home-assistant` e um share NFS **Read/Write** para `<IP Tailscale do notebook>/32` com as mesmas opções do `immich-data`. Coloque o path em `nas_storage_exports.home_assistant` e rode `make plan` e `make apply`.
2. **Primeiro acesso (direto, sem o proxy):** abra `http://<IP do notebook>:8123` (LAN ou IP Tailscale do notebook; funciona por causa do `hostNetwork`) e crie o usuário dono. Pelo `https://casa.<sua-tailnet>` o HA responde 400 até o passo seguinte.
3. **Confiar no proxy do Tailscale:** desde o 2026.8 a config HTTP é só pela UI (o bloco `http:` do YAML é ignorado). Em *Settings → System → Network → HTTP server*, ligue *Trust X-Forwarded-For*, coloque `10.42.0.0/16` em *Trusted proxies* e salve. O HA reinicia e pede confirmação: **confirme em até 5 minutos, ainda pelo acesso direto**, senão ele volta à config anterior. Depois disso `https://casa.<sua-tailnet>` funciona.
4. **Alexa:** ative na conta Amazon o 2FA por app autenticador (SMS não serve) e adicione a integração **Alexa Devices** em *Settings → Devices & services*. A lista de compras vira uma entidade `todo`. Depois, em *Alexa Devices → ⋮ → System options*, **desligue "Enable polling for changes"**: com polling a Amazon devolve 429 (Too Many Requests) a cada poucos ciclos e todas as entidades ficam `unavailable`. As listas continuam sincronizadas nos dois sentidos, porque chegam por push.
5. **grocery-ops:** crie um usuário `grocery-ops` no HA, gere um *long-lived access token* no perfil dele e guarde-o como `*.sops.yaml` no `deploy/` do repo do grocery-ops. O app chama `http://home-assistant.home-assistant.svc:8123` (contrato no ADR 009).

## Observabilidade (OpenTelemetry + Grafana)

Logs, métricas e traces do cluster, do notebook e do NAS chegam por OTLP ao `otel-gateway` e seguem para Prometheus, Loki e Tempo, todos no namespace `observability`. Veja o [ADR 008](docs/adr/008-observability-otel-lgtm.md).

- **Acesso:** `https://grafana.<sua-tailnet>`. O usuário e a senha do admin estão no SOPS:
  ```bash
  sops -d --extract '["stringData"]["admin-password"]' kubernetes/workloads/observability/overlays/tailscale/grafana-admin.sops.yaml
  ```
- **Alertas por e-mail (Gmail):** crie uma [senha de app](https://myaccount.google.com/apppasswords) e preencha `GF_SMTP_USER`, `GF_SMTP_PASSWORD`, `GF_SMTP_FROM_ADDRESS` e `ALERT_EMAIL_TO`. Troque também `GF_SMTP_ENABLED` para `"true"`:
  ```bash
  sops edit kubernetes/workloads/observability/overlays/tailscale/grafana-smtp.sops.yaml
  ```
  Faça push. Depois, em *Alerting → Contact points → email*, use *Test* para confirmar. As regras ficam em `kubernetes/workloads/observability/base/alerts/`.
- **Notebook (journald e métricas do host):** o role `otel_host_agent` instala o `otelcol-contrib` como serviço. Ligue-o no `local.yaml`, como var de host, com `otel_host_agent_enabled: true` e `otel_host_agent_endpoint: otel:4317`, e rode `make apply`.
- **NAS (pela UI do OMV, uma vez):**
  1. Instale o omv-extras e o plugin `openmediavault-compose`. Em *Services → Compose → Settings*, aponte *Compose Files* e o *Docker storage* para pastas no SSD, **não** no pendrive do sistema.
  2. Em *Services → Compose → Files*, crie o stack `otel-collector` colando o conteúdo de [`hosts/nas/otel-collector/compose.yaml`](hosts/nas/otel-collector/compose.yaml) (a configuração vai embutida) e clique em *Up*. Se o NAS não usar o MagicDNS da tailnet, defina `OTEL_GATEWAY=otel.<sua-tailnet>:4317` no `.env` do stack. Para os alertas de capacidade (`base/alerts/nas.yaml`), defina também no `.env` `NAS_PRIMARY_MOUNT` (disco com os dados) e `NAS_REPLICA_MOUNT` (disco da réplica do backup), com o caminho de montagem de *Storage → File Systems* (ex.: `/srv/dev-disk-by-uuid-...`). O mesmo stack sobe o `smartctl-exporter` (SMART dos discos, inclusive o SSD no case USB) e lê o `/var/log/rsync.log` das tarefas Rsync do OMV: o histórico das réplicas fica 30 dias no Loki (`service_name="nas-rsync"`) e aparece no dashboard *Hosts → NAS - Replicação e discos*. O alerta "réplica sem execução bem-sucedida em 26h" dispara até a primeira tarefa rodar depois do deploy.
  3. Em *Diagnostics → System Logs → Remote* (o nome varia com a versão do OMV), envie o syslog para `127.0.0.1`, porta `5140`, TCP.
  4. O NAS aparece no Grafana com `job="nas-host"` (métricas) e `service_name="nas-host"` (logs). Depois disso, os gráficos do OMV (*System → Monitoring*) podem ser desligados: o collectd/rrd só gravaria no pendrive à toa.
- **Dashboards e alertas da comunidade:** o Grafana já traz pastas prontas: *Hosts* (notebook e NAS), *Kubernetes* (pods e visão do cluster), *Apps* (ArgoCD, CloudNativePG e Immich), *Observabilidade* (coletores OTel, Loki, Tempo e Prometheus), *Rede* (CoreDNS) e *Logs*. Eles ficam versionados em `kubernetes/workloads/observability/base/dashboards/`, com versão e sha256 em `dashboards.lock`; os da comunidade são ajustados por patches jq às nossas métricas OTel. As regras de alerta (`base/alerts/`) derivam de regras da comunidade, com `severity` `critical`, `warning` ou `info`.
  ```bash
  scripts/vendor-dashboards.sh --check        # offline: o que está versionado bate com o lock
  scripts/vendor-dashboards.sh --update       # sobe a versão de um dashboard (edite o lock antes)
  scripts/check-dashboard-metrics.py kubernetes/workloads/observability/base/dashboards --prometheus http://localhost:9090
  ```
  O último comando (rode com `kubectl port-forward` no Prometheus) lista as métricas usadas nos dashboards que o Prometheus não tem. Rode-o também a cada upgrade do coletor: os nomes OTel mudam entre versões.
- **Retenção:** métricas por 30 dias (ou 6 GB), logs por 14 dias e traces por 7 dias, tudo no disco do notebook.
- **Instrumentar um app:** envie OTLP para `otel-agent.observability.svc:4317` (gRPC) ou `:4318` (HTTP).

## Segredos de apps (KSOPS)

1. Crie o Secret em texto claro ao lado do app, por exemplo `kubernetes/workloads/<app>/base/<nome>.sops.yaml`, e criptografe **no lugar**:
   ```bash
   sops encrypt --in-place kubernetes/workloads/<app>/base/<nome>.sops.yaml
   ```
   O `.sops.yaml` escolhe os destinatários pelo caminho (WSL + cluster) e criptografa só `data`/`stringData`.
2. Declare um generator KSOPS na kustomization. O modelo é [secret-generator.yaml](kubernetes/workloads/hello-world/base/secret-generator.yaml):
   ```yaml
   generators:
     - secret-generator.yaml
   ```
3. Commit e push. O ArgoCD descriptografa no render e aplica o Secret.

Para editar depois, use `sops kubernetes/workloads/<app>/base/<nome>.sops.yaml`. No pre-commit e no CI, que não têm chave, o `scripts/ksops-stub.py` faz o papel do KSOPS: gera o Secret com valores placeholder só para validar a estrutura.

A chave `tests/ci-age.key` é **pública** e só serve para o demo do hello-world rodar no e2e. O hook `sops-encrypted` barra qualquer outro arquivo criptografado para ela.

## Apps de outros repos

Apps próprias ficam em repos separados da org, gerados a partir do template [bernats-homelab/repotpl-k8s-app](https://github.com/bernats-homelab/repotpl-k8s-app). O repo da app tem código, `Dockerfile` e kustomize em `deploy/`. Aqui fica só a Application, fixada numa tag, como fazemos com as versões dos charts (veja o [ADR 007](docs/adr/007-external-apps.md)).

### Publicar uma app

1. No repo da app, siga o README do template: `scripts/init.sh <nome>` e depois *Actions → release* com `vX.Y.Z`.
2. Aqui, abra um PR com a app em [kubernetes/apps/values.yaml](kubernetes/apps/values.yaml). O resumo do job de release mostra o trecho pronto:
   ```yaml
   apps:
     <nome>:
       repoURL: https://github.com/bernats-homelab/<repo>
       targetRevision: v0.1.0
   ```
3. Depois do merge, o ArgoCD cria o namespace `<nome>` e sincroniza `deploy/overlays/tailscale`, que fica em `https://<nome>.<sua-tailnet>`.

Para uma versão nova, rode o release no repo da app e abra o PR trocando o `targetRevision`. O `values.schema.json` só aceita repos `bernats-homelab/*` ou `Bemesko/*` e tags `vX.Y.Z`.

Repos da conta pessoal `Bemesko` (por exemplo [grocery-ops](https://github.com/Bemesko/grocery-ops)) também são aceitos, mas precisam ser **públicos**, assim como o pacote GHCR deles: a credencial da GitHub App só cobre a org.

As Applications rodam no AppProject `homelab-apps`. Ele não permite recursos cluster-scoped (fora `Namespace`) nem os namespaces do sistema e da plataforma. O e2e sincroniza o próprio template (`smokeApp`, Ansible `external_apps_smoke_enabled=true`) para cobrir esse caminho.

### Repos e imagens privados (uma vez)

1. **GitHub App** (org → *Settings → Developer settings → GitHub Apps → New*):
   - *Repository permissions → Contents: Read-only*, sem webhook;
   - instale na org em *All repositories*. A credencial vale para todo repo com o prefixo `https://github.com/bernats-homelab`, inclusive este;
   - gere uma *private key*.
2. **PAT classic** só com `read:packages` (o GHCR não aceita GitHub App nem fine-grained para pull).
3. Preencha em `sops ansible/secrets/secrets.sops.yaml`:
   - `argocd_github_app_id`, `argocd_github_app_installation_id` e `argocd_github_app_private_key` (o PEM inteiro);
   - `ghcr_pull_username` e `ghcr_pull_token`.

   Depois rode `make plan` → `make apply`. O Ansible cria o Secret `argocd/repo-creds-bernats-homelab` e o `/etc/rancher/k3s/registries.yaml`; a criação do `registries.yaml` reinicia o k3s uma vez.

Os dois são opcionais: sem eles, apps de repos públicos com imagens públicas já funcionam.

## Uso

| Comando | O que faz |
|---|---|
| `make plan` | Dry-run (`--check --diff`) contra o notebook |
| `make apply` | Roda `lint` e depois aplica |
| `make idempotency` | Reaplica e falha se algo mudar |
| `make kernel-upgrade` | Instala o kernel novo, reinicia o notebook e só remove o antigo se nó, Applications, Postgres e AppArmor estiverem ok ([ADR 010](docs/adr/010-notebook-os-updates.md)) |
| `make kubeconfig` | Grava `~/.kube/notebook.yaml` apontando para `https://<host>.<tailnet>:6443` |
| `make reset` | Remove o k3s (pede confirmação; não toca Tailscale nem SSH) |
| `make test` | lint + helm unittest + render/kubeconform/kube-linter |

Fluxo normal: `make plan` → revisar o diff → `make apply`.

Por padrão os targets pedem a senha do sudo (`--ask-become-pass`). Se o sudo do notebook não pede senha (`NOPASSWD`), passe `ASK_BECOME_PASS=0`, por exemplo `make apply ASK_BECOME_PASS=0`.

```bash
export KUBECONFIG=~/.kube/notebook.yaml
kubectl -n argocd get applications
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
```

Depois do bootstrap, tudo dentro do cluster é **GitOps**: altere `kubernetes/` e faça push. O ArgoCD sincroniza sozinho.

## Safety nets

### Pre-commit (WSL e CI)

| Hook | Garante |
|---|---|
| `trailing-whitespace`, `end-of-file-fixer`, `mixed-line-ending`, `check-yaml`, `check-json`, `check-merge-conflict`, `detect-private-key` | Higiene básica e LF |
| `gitleaks` (+ regras `AGE-SECRET-KEY` e `*.ts.net`) | Nenhum segredo nem o nome da tailnet no repo |
| `sops-encrypted` | Todo `*.sops.yaml` está criptografado (só `apiVersion`/`kind`/`metadata`/`type` podem ficar em claro, via `unencrypted_regex`); a chave pública de teste do CI não é usada fora do demo |
| `no-local-inventory`, `no-kubeconfig` | Hostname/usuário e kubeconfigs não são commitados |
| `no-lockout` | Nenhuma task altera Tailscale, SSH, firewall ou rede do host |
| `yamllint --strict`, `ansible-lint` (profile `production`) | Qualidade de YAML/Ansible, FQCN, `changed_when`, permissões |
| `shellcheck`, `shfmt` | Scripts |
| `actionlint` | Workflow do CI |
| `helm-lint` (com `values.schema.json`), `helm-unittest` | Chart app-of-apps |
| `validate-manifests` | `kubeconform -strict` (k8s 1.37 + CRD Application) e `kube-linter` |

O `validate-manifests` baixa os schemas na primeira execução e os guarda em cache em `.cache/kubeconform`.

### CI ([.github/workflows/ci.yaml](.github/workflows/ci.yaml))

- **lint**: roda o pre-commit em todos os arquivos.
- **render**: roda `helm unittest` e renderiza os charts upstream (argo-cd, tailscale-operator, cloudnative-pg, immich, prometheus, loki, tempo, grafana, otel-agent/otel-gateway) com os nossos values, validando tudo com kubeconform.
- **e2e**: no runner `ubuntu-26.04`:
  1. gera uma chave age efêmera com segredos dummy;
  2. roda o `site.yaml` completo com `tailscale_enabled=false`, sincronizando o próprio SHA do PR;
  3. roda o playbook de novo e exige **changed=0**;
  4. confere que as Applications estão Synced/Healthy, que o hello-world responde, que o Secret demo foi descriptografado pelo KSOPS, que o Postgres (CNPG + VectorChord) está pronto que o Immich responde `/api/server/ping` e que a app externa de smoke (o template `repotpl-k8s-app`, no AppProject `homelab-apps`) responde `/healthz`. No CI, o Immich usa `local-path` em vez do NAS;
  5. roda `reset.yaml`.

Recomendado: proteção de branch na `main` exigindo os jobs `lint`, `render` e `e2e`.

## Troubleshooting

- **Firewall ativo no notebook.** O preflight avisa, mas não altera nada. Se pods não alcançarem a API, libere manualmente os ranges do k3s (`10.42.0.0/16` pods, `10.43.0.0/16` services).
- **O ArgoCD não abre em `https://argocd.<tailnet>`.** Confira a policy e as tags do Tailscale e rode `kubectl -n tailscale logs deploy/operator`.
- **Postgres trava na subida, "too many clients" ou pod preso em `Terminating`** (Ubuntu 26.04, kernel 7.0.0-42+). O `dmesg` mostra `apparmor="DENIED" operation="signal" ... peer="cri-containerd.apparmor.d//&unconfined"`. O role `base` instala um perfil AppArmor corrigido para os containers (workaround de [containerd#14485](https://github.com/containerd/containerd/issues/14485)). Rode `make apply`; o perfil é substituído no kernel e vale também para os containers em execução.
- **Ansible ignora `ansible.cfg`.** Use os targets do `make`, ou exporte `ANSIBLE_CONFIG=$PWD/ansible/ansible.cfg`.

## Estrutura

```
ansible/              playbooks (site, reset), roles, inventário de exemplo/CI, segredos SOPS
kubernetes/apps/      Helm chart app-of-apps (Applications do ArgoCD) + testes
kubernetes/values/    values dos charts upstream
kubernetes/workloads/ manifests (kustomize) dos workloads
kubernetes/bootstrap/ Application raiz (template renderizado pelo Ansible)
hosts/nas/            arquivos aplicados à mão no NAS pela UI do OMV (coletor OTel)
scripts/              setup do controle e checagens usadas pelo pre-commit/CI (inclui o stub do KSOPS)
tests/ci-age.key      chave age PÚBLICA de teste do CI (só o demo do hello-world)
docs/adr/             decisões de arquitetura
```
