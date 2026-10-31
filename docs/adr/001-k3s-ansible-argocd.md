# 001 — k3s + Ansible + ArgoCD no notebook

- **Status:** aceito
- **Data:** 2026-10-31

## Contexto

O cluster precisa rodar num notebook pessoal com Ubuntu 26.04, com poucos recursos, e ser reproduzível depois de uma reinstalação do sistema.

## Decisão

- **k3s** direto no host, single-node. É um binário só, consome pouco, e o Traefik embutido fica desligado porque o ingress é feito pelo Tailscale Operator.
- **Ansible** é idempotente e cobre só o host e o bootstrap: pacotes, sysctl, k3s, Secrets iniciais, `helm install` do ArgoCD e Application raiz.
- **ArgoCD app-of-apps** (Helm chart em `kubernetes/apps`) cuida de tudo que roda dentro do cluster. O próprio ArgoCD é autogerenciado.
- O ArgoCD é instalado pelo Ansible **só se ainda não existir**. Depois disso é o ArgoCD que o gerencia, para que os dois não briguem pelo release.

## Consequências

- Mudanças no cluster são feitas via Git; o Ansible só volta a ser necessário para host/k3s.
- A versão do chart do ArgoCD fica num único lugar (`kubernetes/apps/values.yaml`).
