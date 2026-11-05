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
                                               └─ immich                → https://fotos.<sua-tailnet>
                                                    └─ NFS (tailnet) ──▶ NAS openmediavault (fotos ro, immich-data rw)
```

## Garantias de segurança

- **Sem lockout.** O playbook nunca mexe no Tailscale, no SSH, no firewall ou na rede do host. O role `tailscale_check` só lê o status, e o hook `no-lockout` barra qualquer task que tente alterar essas coisas.
- **Nada identificável no repo.** O inventário real fica em `ansible/inventory/local.yaml` (ignorado pelo git e barrado por hook). O nome da tailnet (`*.ts.net`) é descoberto em runtime e barrado pelo gitleaks. Os kubeconfigs ficam em `~/.kube/`.
- **Segredos com SOPS + age.** A chave privada fica só no WSL. O Ansible descriptografa no controller e cria os Secrets do bootstrap com `no_log` (veja [ADR 002](docs/adr/002-sops-age-secrets.md)). Os segredos dos apps são commitados criptografados ao lado do app, e o ArgoCD os descriptografa com KSOPS usando uma chave age própria do cluster (veja [ADR 004](docs/adr/004-ksops.md)).
- **Tampa fechada na energia não suspende.** O role `power` configura o `systemd-logind` (`HandleLidSwitchExternalPower=ignore` e `HandleLidSwitchDocked=ignore`) e confere via D-Bus que o valor efetivo foi aplicado. Na bateria continua valendo o padrão do sistema (suspender).
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

Preencha as variáveis de `inventory.example.yaml`: `nas_storage_enabled: true`, `nas_storage_host` e `nas_storage_exports.{photos,data}`, que são os paths `/export/...`. Faça isso **antes** do primeiro `make apply` com o Immich. As PVCs são imutáveis, e com `nas_storage_enabled: false` elas seriam criadas em `local-path`.

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

## Uso

| Comando | O que faz |
|---|---|
| `make plan` | Dry-run (`--check --diff`) contra o notebook |
| `make apply` | Roda `lint` e depois aplica |
| `make idempotency` | Reaplica e falha se algo mudar |
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
- **render**: roda `helm unittest` e renderiza os charts upstream (argo-cd, tailscale-operator, cloudnative-pg, immich) com os nossos values, validando tudo com kubeconform.
- **e2e**: no runner `ubuntu-26.04`:
  1. gera uma chave age efêmera com segredos dummy;
  2. roda o `site.yaml` completo com `tailscale_enabled=false`, sincronizando o próprio SHA do PR;
  3. roda o playbook de novo e exige **changed=0**;
  4. confere que as Applications estão Synced/Healthy, que o hello-world responde, que o Secret demo foi descriptografado pelo KSOPS, que o Postgres (CNPG + VectorChord) está pronto e que o Immich responde `/api/server/ping`. No CI, o Immich usa `local-path` em vez do NAS;
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
scripts/              setup do controle e checagens usadas pelo pre-commit/CI (inclui o stub do KSOPS)
tests/ci-age.key      chave age PÚBLICA de teste do CI (só o demo do hello-world)
docs/adr/             decisões de arquitetura
```
