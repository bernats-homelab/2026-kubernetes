# 011 — Syncthing do NAS gerenciado pelo Ansible

- **Status:** aceito
- **Data:** 2026-11-11
- **Atualiza:** [005](005-immich-nas-nfs.md) e [008](008-observability-otel-lgtm.md), na parte em que "o Ansible não toca no NAS"

## Contexto

O vault do Obsidian (`borbsidian`) fica no NAS e chega ao celular pelo Syncthing. O Syncthing foi instalado à mão no NAS em 2026-08 (pacote do apt.syncthing.net) e iniciado como **root**, sem nenhuma instância `syncthing@` habilitada no systemd. Em algum reboot ele não voltou: o índice parou de ser gravado em 2026-10-01 e nada mais sincronizou.

A instalação manual tinha mais três problemas:

- **Arquivos de root no vault.** O vault é do `Bernardo` (uid 1000:users). O Obsidian do cluster grava por NFS com `all_squash` 1000:100 e não consegue regravar arquivos de root.
- **Estado no pendrive.** A config e o índice ficavam em `/root/.local/state`, no pendrive do sistema, que leva cerca de 230 ms por escrita pequena.
- **Peer sobrando.** A pasta continuava compartilhada com o notebook do k3s, que já lê o vault por NFS ([ADR 006](006-obsidian-nas-nfs.md)).

O openmediavault não gerencia esta instalação do Syncthing pela UI. Um stack compose resolveria o boot, mas a config (devices, pastas) continuaria manual pela GUI.

## Decisão

- O Ansible passa a alterar o NAS **somente** para o Syncthing, pelo role `nas_syncthing`. O resto do NAS continua pela UI do OMV, e o `nas_storage` continua só verificando.
- **Acesso:** um segundo play em `site.yaml` usa um grupo `nas` no inventário privado. A conexão é SSH como root com a chave `ansible-control@wsl`, que fica permanente no `/root/.ssh/authorized_keys` do NAS. No CI não existe grupo `nas`, então o play não roda.
- **Pacote:** o `.deb` do release do GitHub é instalado com versão e sha256 fixados em `group_vars/all` e fica em `hold`.
- **Serviço:** `syncthing@Bernardo` habilitado no boot. Um drop-in aponta `--home` para `appdata/syncthing` no SSD de dados, usa `RequiresMountsFor=` com o home e as pastas para não subir antes do disco, e define `UMask=0002`.
- **Migração:** a identidade (cert/key), a config e o índice da instalação de root são copiados uma vez, então o device ID não muda. Os arquivos de root nas pastas passam para `Bernardo:users`. O diretório antigo em `/root` fica como backup.
- **Config declarativa pela REST API:**
  - opções, endereço da GUI (só `127.0.0.1:8384`, acessada por túnel SSH), devices e pastas vêm do inventário;
  - um device fora da lista é removido;
  - uma pasta fora da lista só gera um aviso, porque apagar pasta é destrutivo demais para fazer em silêncio.

## Consequências

- Mudanças feitas na GUI do Syncthing (devices, pastas, opções gerenciadas) são desfeitas no próximo `make apply`. Parear um device novo é: adicionar o ID no `local.yaml`, rodar `make apply` e aceitar no outro lado.
- O playbook ganha escrita no NAS que guarda as fotos, com root SSH. O escopo fica limitado ao role e é revisado no PR. O pre-commit `no-lockout` continua valendo para o play novo.
- Atualizar o Syncthing é trocar a versão e o sha256 em `group_vars/all`. Os timers do apt no NAS seguem desligados.
