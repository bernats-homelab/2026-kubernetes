# 007 — Apps de outros repos da org

- **Status:** aceito
- **Data:** 2026-11-02

## Contexto

Até aqui todo workload morava neste repo (`kubernetes/workloads/`). Para apps próprias isso mistura o ciclo de vida da app (código, imagem, versão) com o da plataforma. A ideia é cada app ter seu repo na org `bernats-homelab`, inclusive privado, e o cluster publicar uma versão escolhida aqui, como já fazemos com os charts de terceiros.

## Decisão

- **Template `bernats-homelab/repotpl-k8s-app`.** Traz o formato que este repo espera:
  - `deploy/base`, sem Ingress, usado no CI;
  - `deploy/overlays/tailscale`, usado no notebook;
  - workflow de release (imagem no GHCR → digest gravado em `deploy/base` → tag `vX.Y.Z`);
  - CI com as mesmas validações daqui (kubeconform, kube-linter, sops, gitleaks) e um e2e em k3s.
- **Aqui fica só a Application.** Cada entrada de `apps:` em `kubernetes/apps/values.yaml` vira uma Application (`templates/external-apps.yaml`) que sincroniza `deploy/` do repo da app.
  - O `values.schema.json` exige repo `bernats-homelab/*` e tag semver: promover uma versão é um PR aqui, revisável como a troca de versão de um chart.
- **AppProject `homelab-apps`.** Só aceita repos da org, nenhum recurso cluster-scoped além de `Namespace`, e nega os namespaces do sistema e da plataforma.
  - Um repo de app com problema não consegue mexer no ArgoCD, no Tailscale, no CNPG ou nos dados do Immich.
- **Credenciais (opcionais), criadas pelo Ansible a partir de `ansible/secrets/` (rota do ADR 002):**

  | Para | Credencial | Por quê |
  |---|---|---|
  | Git | GitHub App com *Contents: read-only*, num template `repo-creds` com o prefixo da org | sem expiração, revogável, suporte nativo no ArgoCD |
  | Imagens | PAT classic `read:packages` no `registries.yaml` do k3s | o GHCR não aceita App nem fine-grained; no nó, nenhuma app precisa de `imagePullSecret` |

- **Segredos das apps** com KSOPS, como os daqui: o `.sops.yaml` do template usa as mesmas chaves públicas (WSL + cluster).
- **Smoke test no e2e.** Com `external_apps_smoke_enabled=true` (só no CI), o chart sincroniza o próprio template (`smokeApp`, numa tag publicada) e o `e2e-assert.sh` confere o `/healthz`.

## Consequências

- **Nova versão de app = release no repo dela + PR aqui.** Nada sobe no cluster sem passar por este repo, e o e2e daqui não quebra por causa da `main` de uma app.
- **O e2e depende de um repo externo:** a tag do template em `smokeApp` e o pacote GHCR público dele. Trocar essa tag é um PR como qualquer outro.
- **Credenciais privadas não são testadas no CI.** O CI não tem GitHub App nem PAT, então repos e imagens privados só são exercitados no notebook.
- **A credencial da GitHub App vale para o prefixo da org inteira**, incluindo este repo. Se a App não estiver instalada num repo, o ArgoCD não consegue ler esse repo.
- **Quem tem push num repo de app consegue fazer o ArgoCD descriptografar segredos dele** (chave do cluster), mas só dentro do namespace da app, por causa do AppProject.
- **A chave de uma app em `apps:` é o nome da Application e, por padrão, do namespace.** O schema barra os nomes das Applications da plataforma.
