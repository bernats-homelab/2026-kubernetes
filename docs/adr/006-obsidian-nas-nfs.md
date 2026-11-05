# 006 — Obsidian no navegador com o vault do NAS via NFS

- **Status:** aceito
- **Data:** 2026-11-05

## Contexto

Queremos o Obsidian desktop acessível de qualquer dispositivo da tailnet pelo navegador. O vault (`borbsidian`, ~9.600 arquivos, ~530 MB) já vive no NAS, dentro da área com backup, e é editado por outros dispositivos via Syncthing/SMB.

## Decisão

- **Imagem `linuxserver/obsidian`**, e não a `sytone/obsidian-remote` citada em tutoriais.
  - A da linuxserver é mantida e tem tags versionadas, o que permite fixar versão e digest, como o resto do repo.
  - A da sytone só publica `latest`.
- **O vault é montado do NAS por NFS (rw), sem cópia nem sincronização no cluster.**
  - Usa o mesmo caminho do Immich (ADR 005): o OMV é configurado pela UI, o role `nas_storage` verifica o export e cria o PV, e a PVC vem do git.
  - O role passou a receber uma lista de volumes (`nas_storage_volumes`) em vez de ser específico do Immich.
  - O `all_squash` para `1000:100` faz os arquivos criados pelo Obsidian ficarem com o mesmo dono dos já existentes.
- **O estado do app (`/config`) fica em local-path, no notebook.** É estado reconstruível: o vault aberto, o perfil do Electron.
- **Acesso só pela tailnet e com basic auth.**
  - O container tem terminal web. Por isso, além do ACL da tailnet, há usuário e senha (`CUSTOM_USER`/`PASSWORD`, num Secret SOPS no overlay `tailscale`).
  - `allowPrivilegeEscalation: false` desliga o sudo dentro do container.
  - O CI usa o `base`, que não tem segredo, Ingress nem auth.

## Alternativa descartada: Syncthing dentro do cluster

O vault ficaria em local-path, com um Syncthing no cluster como mais um peer. O Obsidian veria as mudanças em tempo real, e os conflitos virariam `.sync-conflict`.

Ficou de fora por agora porque traz mais peças (outro app, chaves do Syncthing em SOPS, pareamento manual) e uma segunda cópia do vault fora do backup do NAS.

## Consequências

- **O inotify não atravessa NFS.** O Obsidian do cluster não vê mudanças feitas por outros dispositivos até recarregar (*Reload app without saving*), e pode sobrescrever uma edição mais nova. A regra é editar num lugar por vez. Se isso incomodar, a alternativa acima é o próximo passo.
- **A imagem inicia como root e escreve no rootfs**, por causa do s6-overlay que troca para o PUID. São exceções explícitas no kube-linter, nas anotações do Deployment.
- **O s6-overlay é multiprocesso e sinaliza os próprios filhos.** Em Ubuntu 26.04 isso depende do perfil AppArmor corrigido no role `base` (containerd#14485).
- **A montagem de teste do `nas_storage` grava e apaga um arquivo na raiz do vault.** Se outro dispositivo sincronizar nesse instante, o arquivo pode aparecer por um momento lá também.
