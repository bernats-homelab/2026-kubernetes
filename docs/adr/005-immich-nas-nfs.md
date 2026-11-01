# 005 — Immich com as fotos do NAS via NFS

- **Status:** aceito
- **Data:** 2026-11-01

## Contexto

O Immich roda no k3s do notebook e precisa exibir, **somente leitura**, as fotos e vídeos do NAS `thinkpad` (openmediavault, na tailnet). A coleção tem de 200 GB a 1 TB; o notebook tem ~50 GB livres. O NAS expunha só SMB.

## Decisão

- **NFS, e não SMB.**
  - O kubelet monta `nfs:` nativamente: não precisa de CSI driver no cluster, só do `nfs-common` no host.
  - Não há credencial para guardar.
  - Os dois lados são Linux, então permissões e nomes de arquivo funcionam sem tradução.
  - O acesso fica restrito ao IP Tailscale do notebook, e o tráfego já vai cifrado pelo WireGuard.
- **O OMV é configurado pela UI dele, e o Ansible só verifica.**
  - O OMV mantém a configuração num banco próprio e regenera o `/etc/exports`. Automatizar exigiria `omv-rpc` + `omv-salt`, que é frágil entre versões e daria ao playbook escrita no NAS das fotos.
  - O role `nas_storage` só lê (`showmount`) e faz uma montagem temporária de teste, incluindo uma escrita no export de dados.
- **Os PVs vêm do Ansible; as PVCs vêm do git.**
  - O PV carrega hostname e paths do NAS, que ficam no inventário privado, junto com o hostname do notebook.
  - A PVC só declara a necessidade do app. O `claimRef` garante que só a PVC do Immich usa cada PV.
- **Onde fica cada dado:**

  | Dado | Onde | Por quê |
  |---|---|---|
  | Fotos/vídeos originais | NAS, export `ro` | o Immich nunca altera os originais |
  | Thumbnails, previews, transcodes, dumps do banco | NAS, export `rw` dedicado (`immich-data`) | ~12 a 70 GB, não cabe no notebook |
  | Postgres (CNPG + VectorChord) | disco do notebook (`local-path`) | banco em NFS corrompe com facilidade |

- **Backup do banco** com o job nativo do Immich (dump diário em `immich-data/backups`, 14 cópias). O banco some com um `make reset`, mas os dumps ficam no NAS.
- **HEVC aceito sem transcode** (`ffmpeg.acceptedVideoCodecs`) e **ML desligado**. Os dois evitam dias de CPU no i7-7500U e GBs extras no NAS.

## Consequências

- **Firefox e HEVC:** o Firefox pode não tocar vídeos HEVC. Chrome/Edge, Safari e o app tocam.
- **Fotos novas não aparecem na hora.** O `library.watch` não funciona sobre NFS; elas aparecem no próximo scan agendado.
- **O CI não tem NAS.** O e2e sobe Immich + CNPG com `local-path` (`nasStorage.enabled=false`). O caminho NFS é coberto pelo assert e pela montagem de teste do `nas_storage`, que rodam no notebook.
- **PVC é imutável.** Trocar `nasStorage` depois que as PVCs existem exige apagá-las.
- **O Postgres do Immich não tem um segredo nosso:** o CNPG gera o `immich-database-app`.
