# Linguagem e Toolchain

- Ansible (ansible-core 2.21, coleções fixadas em `ansible/requirements.yml`) para o bootstrap do host
- k3s single-node; ArgoCD (app-of-apps em Helm) para tudo dentro do cluster; kustomize para workloads
- SOPS + age para segredos; chave privada só na máquina de controle (WSL)
- Ferramentas da máquina de controle com versão + sha256 fixados em `scripts/setup-control-node.sh`

# Estrutura do Repositório

- `ansible/`: `site.yaml` (preflight → base → power → tailscale_check → k3s → cluster_bootstrap → kubeconfig) e `reset.yaml`
- `kubernetes/apps/`: chart app-of-apps; `values.yaml` é a FONTE ÚNICA das versões de charts (o Ansible também lê)
- `kubernetes/workloads/<app>/{base,overlays/tailscale}`: `base` é usado no CI (sem Tailscale)
- `docs/adr/NNN-*.md`: decisões de arquitetura

# Restrições

- O notebook é acessado por SSH pela tailnet: NUNCA criar tasks que alterem Tailscale, SSH, firewall ou rede do host (hook `no-lockout`)
- Nunca versionar hostname, usuário, nome da tailnet (`*.ts.net`) ou kubeconfig; o inventário real é `ansible/inventory/local.yaml` (gitignored)
- Toda versão nova vem com sha256 (binários) ou digest (imagens)
- Variáveis registradas/definidas em roles levam o prefixo do role (ansible-lint `production`)
- Todo `command`/`shell` tem `changed_when`/`creates`; o e2e exige changed=0 na segunda execução
- Mudança de versão de chart: só em `kubernetes/apps/values.yaml`

# Testes

- `make test`: pre-commit + helm unittest + render/kubeconform/kube-linter
- CI `e2e`: sobe k3s + ArgoCD no runner, confere idempotência, Applications Healthy e reset
- Contra o notebook: `make plan` (check/diff) antes de `make apply`
