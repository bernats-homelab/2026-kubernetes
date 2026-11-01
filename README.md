# 2026-kubernetes

Bootstrap e configuração de um cluster **k3s single-node** no notebook pessoal (Ubuntu 26.04).
Tudo é aplicado **remotamente**: o Ansible roda no WSL desta máquina e conecta no notebook por SSH pela tailnet.

```
WSL (controle)  ──ssh via Tailscale──▶  notebook (Ubuntu 26.04)
  ansible + sops/age                      k3s
                                           └─ ArgoCD (app-of-apps, GitOps deste repo)
                                               ├─ tailscale-operator  → Ingress na tailnet
                                               ├─ argocd (self-managed) → https://argocd.<sua-tailnet>
                                               └─ hello-world           → https://hello.<sua-tailnet>
```

## Garantias de segurança

- **Sem lockout.** O playbook nunca mexe no Tailscale, no SSH, no firewall ou na rede do host. O role `tailscale_check` só lê o status, e o hook `no-lockout` barra qualquer task que tente alterar essas coisas.
- **Nada identificável no repo.** O inventário real fica em `ansible/inventory/local.yaml` (ignorado pelo git e barrado por hook). O nome da tailnet (`*.ts.net`) é descoberto em runtime e barrado pelo gitleaks. Os kubeconfigs ficam em `~/.kube/`.
- **Segredos com SOPS + age.** A chave privada fica só no WSL. O Ansible descriptografa no controller e cria os Secrets com `no_log` (veja [ADR 002](docs/adr/002-sops-age-secrets.md)).
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
| `sops-encrypted` | Todo `*.sops.yaml` está criptografado |
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
- **render**: roda `helm unittest` e renderiza os charts upstream (argo-cd, tailscale-operator) com os nossos values, validando tudo com kubeconform.
- **e2e**: no runner `ubuntu-26.04`:
  1. gera uma chave age efêmera com segredos dummy;
  2. roda o `site.yaml` completo com `tailscale_enabled=false`, sincronizando o próprio SHA do PR;
  3. roda o playbook de novo e exige **changed=0**;
  4. confere que as Applications estão Synced/Healthy e que o hello-world responde;
  5. roda `reset.yaml`.

Recomendado: proteção de branch na `main` exigindo os jobs `lint`, `render` e `e2e`.

## Troubleshooting

- **Firewall ativo no notebook.** O preflight avisa, mas não altera nada. Se pods não alcançarem a API, libere manualmente os ranges do k3s (`10.42.0.0/16` pods, `10.43.0.0/16` services).
- **O ArgoCD não abre em `https://argocd.<tailnet>`.** Confira a policy e as tags do Tailscale e rode `kubectl -n tailscale logs deploy/operator`.
- **Ansible ignora `ansible.cfg`.** Use os targets do `make`, ou exporte `ANSIBLE_CONFIG=$PWD/ansible/ansible.cfg`.

## Estrutura

```
ansible/              playbooks (site, reset), roles, inventário de exemplo/CI, segredos SOPS
kubernetes/apps/      Helm chart app-of-apps (Applications do ArgoCD) + testes
kubernetes/values/    values dos charts upstream
kubernetes/workloads/ manifests (kustomize) dos workloads
kubernetes/bootstrap/ Application raiz (template renderizado pelo Ansible)
scripts/              setup do controle e checagens usadas pelo pre-commit/CI
docs/adr/             decisões de arquitetura
```
