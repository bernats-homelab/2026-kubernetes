# Linguagem e Toolchain

- Ansible (ansible-core 2.21, coleções fixadas em `ansible/requirements.yml`) para o bootstrap do host
- k3s single-node; ArgoCD (app-of-apps em Helm) para tudo dentro do cluster; kustomize para workloads
- SOPS + age para segredos; chave privada só na máquina de controle (WSL)
- Ferramentas da máquina de controle com versão + sha256 fixados em `scripts/setup-control-node.sh`

# Estrutura do Repositório

- `ansible/`: `site.yaml` (preflight → base → power → tailscale_check → k3s → cluster_bootstrap → nas_storage → kubeconfig) e `reset.yaml`
- `kubernetes/apps/`: chart app-of-apps; `values.yaml` é a FONTE ÚNICA das versões de charts (o Ansible também lê)
- `kubernetes/workloads/<app>/{base,overlays/tailscale}`: `base` é usado no CI (sem Tailscale)
- Apps de outros repos da org ou da conta pessoal `Bemesko`, só públicos (template `bernats-homelab/repotpl-k8s-app`): só a entrada em `apps:` de `kubernetes/apps/values.yaml`; os kustomize ficam no `deploy/` do repo da app
- `docs/adr/NNN-*.md`: decisões de arquitetura

# Restrições

- O notebook é acessado por SSH pela tailnet: NUNCA criar tasks que alterem Tailscale, SSH, firewall ou rede do host (hook `no-lockout`)
- Nunca versionar hostname, usuário, nome da tailnet (`*.ts.net`) ou kubeconfig; o inventário real é `ansible/inventory/local.yaml` (gitignored)
- Toda versão nova vem com sha256 (binários) ou digest (imagens)
- Variáveis registradas/definidas em roles levam o prefixo do role (ansible-lint `production`)
- Todo `command`/`shell` tem `changed_when`/`creates`; o e2e exige changed=0 na segunda execução
- Mudança de versão de chart: só em `kubernetes/apps/values.yaml`
- Apps externas sempre por tag `vX.Y.Z` (nunca branch) e no AppProject `homelab-apps`; credencial da GitHub App e do GHCR só em `ansible/secrets/` (opcionais)
- Segredos de apps: `*.sops.yaml` ao lado do app + generator KSOPS; criptografe no caminho final (o `.sops.yaml` escolhe os destinatários). Nunca use a chave de teste do CI (`tests/ci-age.key`, pública) fora de `kubernetes/workloads/hello-world/`
- Segredos do bootstrap (`ansible/secrets/`) são só da chave do WSL
- O NAS (openmediavault) é configurado pela UI dele: NUNCA criar tasks que alterem o NAS. O role `nas_storage` só verifica os exports e cria os PVs; hostname e paths do NAS ficam no `local.yaml`
- Imagens do Immich/Postgres por digest; a versão do Immich fica em `kubernetes/values/immich.yaml` (o chart não acompanha as releases)

# Testes

- `make test`: pre-commit + helm unittest + render/kubeconform/kube-linter
- CI `e2e`: sobe k3s + ArgoCD no runner, confere idempotência, Applications Healthy e reset
- Contra o notebook: `make plan` (check/diff) antes de `make apply`
