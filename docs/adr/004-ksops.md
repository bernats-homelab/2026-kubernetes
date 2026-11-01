# 004 — Segredos dos apps com KSOPS no ArgoCD

- **Status:** aceito
- **Data:** 2026-11-01
- **Evolui:** [002](002-sops-age-secrets.md)

## Contexto

O ADR 002 deixou os segredos a cargo do Ansible no bootstrap. Isso serve para o OAuth do Tailscale, mas cada app novo com segredo exigiria uma task nova e um `make apply`, e o segredo ficaria fora do GitOps. A ideia é commitar o segredo criptografado ao lado do app e deixar o ArgoCD sincronizar.

## Decisão

- **KSOPS** no `repo-server` do ArgoCD. Um init container copia o binário (imagem fixada por digest), e `kustomize.buildOptions` habilita `--enable-alpha-plugins --enable-exec`. Os apps declaram um generator `viaduct.ai/v1 ksops` que aponta para os seus `*.sops.yaml`.
- **Chave age própria do cluster**, separada da do WSL:
  - a privada fica no Secret `argocd/sops-age`, que o Ansible cria a partir de `ansible/secrets/secrets.sops.yaml` (rota do ADR 002) antes de o ArgoCD subir;
  - os arquivos em `kubernetes/` são criptografados para as duas chaves (`.sops.yaml`): WSL para editar, cluster para sincronizar;
  - `ansible/secrets/` continua só com a chave do WSL.
- **`unencrypted_regex: ^(apiVersion|metadata|kind|type)$`** nos manifests: só `data`/`stringData` são criptografados. Assim o diff mostra qual Secret mudou, e o render offline consegue gerar a estrutura.
- **Chave de teste do CI** (`tests/ci-age.key`), **pública de propósito**:
  - é destinatária só do demo `kubernetes/workloads/hello-world/base/demo-secret.sops.yaml`, para o e2e exercitar o caminho real (ArgoCD → KSOPS → Secret);
  - o hook `sops-encrypted` barra essa chave em qualquer outro caminho, e o gitleaks só libera esse arquivo.
- **Validação offline com stub.** `scripts/ksops-stub.py` substitui o ksops no pre-commit e no CI. Ele gera o Secret com valores placeholder, valida a estrutura com kubeconform/kube-linter e não precisa de chave.

## Consequências

- **A chave do cluster passa a viver no cluster.** Quem tiver admin do cluster (kubeconfig) ou ler o disco do notebook descriptografa os segredos de `kubernetes/`, mas não os de `ansible/secrets/`. Se ela vazar: gere outra, atualize `.sops.yaml` e `secrets.sops.yaml`, rode `sops updatekeys` nos arquivos de `kubernetes/` e depois `make apply`.
- **A chave do WSL continua sendo a raiz:** ela descriptografa tudo, inclusive a chave do cluster.
- **Recriar o cluster continua sendo só `make apply`:** a chave do cluster vem do `secrets.sops.yaml`.
- **Nenhum segredo real é testado no CI.** O que o e2e garante é o mecanismo (init container, montagem da chave, buildOptions, generator), e não os valores.
