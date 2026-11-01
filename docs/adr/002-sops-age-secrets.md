# 002 — Segredos com SOPS + age, descriptografados pelo Ansible

- **Status:** aceito; segredos dos apps evoluíram para KSOPS em [004](004-ksops.md)
- **Data:** 2026-10-31

## Contexto

O repositório é público. O único segredo hoje é o OAuth client do Tailscale Operator, e o cluster é de notebook e vai ser recriado de vez em quando.

## Opções

| | SOPS + age | Sealed Secrets |
|---|---|---|
| Onde fica a chave privada | arquivo `keys.txt` com você (backup no gerenciador de senhas) | dentro do cluster (gerada pelo controller) |
| O que é criptografado | os valores de qualquer YAML; as chaves continuam legíveis no diff | só `Secret` do Kubernetes (CRD `SealedSecret`) |
| Serve para variáveis do Ansible | sim (`community.sops`) | não |
| Recriar o cluster | basta ter o `keys.txt` | precisa de backup da chave do controller ou selar tudo de novo |
| Integração com o ArgoCD | precisa de plugin (KSOPS/helm-secrets) se o ArgoCD for descriptografar | nativa (é só um manifest) |

## Decisão

SOPS + age, com a descriptografia feita **pelo Ansible no controller** durante o bootstrap, que cria os `Secret` no cluster com `no_log`. A chave privada nunca vai para o notebook nem para o cluster, e o ArgoCD não precisa de plugin.

## Consequências

- Um Secret novo que precise ser gerenciado continuamente pelo ArgoCD vai exigir a migração para KSOPS (com a chave age no cluster). Isso fica como evolução futura.
- O CI usa uma chave age efêmera e segredos dummy, o que exercita o mesmo caminho de descriptografia.
