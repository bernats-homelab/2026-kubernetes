# 011 — Backup off-site do NAS: restic no cluster para um Storage Box da Hetzner

- **Status:** aceito
- **Data:** 2026-11-09

## Contexto

O NAS (OMV) tem duas cópias, ambas em casa: o SSD primário e a réplica em disco USB (tarefas Rsync do OMV às 03:00, só `data-with-backup`). Falta a terceira cópia, fora de casa. Hoje são ~600 GB (`data-with-backup` ~250 GB + `data-without-backup`), com orçamento de até ~US$ 5/mês. Restore lento é aceitável, mas a configuração do provedor tem de ser declarativa.

Preços consultados em 2026-11-08, sem impostos, para 600 GB:

| Opção | Custo/mês | Observação |
|---|---|---|
| **Hetzner Storage Box BX11 (1 TB)** | € 3,20 fixo | Tráfego ilimitado; SFTP/SSH; BX21 (5 TB) a € 10,90 |
| Backblaze B2 | US$ 4,17 (US$ 6,95/TB) | Egress grátis até 3× o armazenado; passa de US$ 5 em ~720 GB |
| Storj | US$ 4,20 + US$ 7/TB de egress | |
| Wasabi | US$ 7,99 (mínimo 1 TB) | |
| Cloudflare R2 | US$ 9 (Standard) / US$ 6 (IA) | Egress grátis |
| AWS S3 Standard | US$ 13,80 (us-east-1) / US$ 24,30 (sa-east-1) | |
| Glacier Deep Archive, GCS Archive, Azure Archive | US$ 0,59–0,72 | Retenção mínima de 180–365 dias; restore de 12–48 h e pago; não combina com `restic prune` |

## Decisão

- **Destino:** Hetzner Storage Box **BX11** em `fsn1`. É o mais barato acima de ~530 GB, sem custo de egress no restore. Entre 1 e ~1,8 TB o B2 voltaria a ser mais barato; acima disso, o BX21.
- **Provisionamento:** **OpenTofu** em `infra/hetzner/` com o provider `hetznercloud/hcloud` (o Storage Box deixou de ser experimental no provider). Ele cria o box, as `access_settings` (só SSH) e o plano de snapshots, e injeta a chave SSH do restic.
  - O **state é versionado no git, criptografado pelo próprio OpenTofu** (pbkdf2 + AES-GCM, `enforced`). Ele contém a senha do box.
  - O token da API e a passphrase do state ficam em `infra/hetzner/secrets.sops.yaml`, que só a chave da WSL abre.
  - `ssh_keys` não pode ser alterado pela API (mudar recriaria o box). Por isso há `ignore_changes` e `prevent_destroy`, além do `delete_protection` do lado da Hetzner.
- **Ferramenta:** **restic** por SFTP (porta 23), com criptografia no cliente, deduplicação e versões. A senha do repositório fica só no Secret SOPS e no gerenciador de senhas.
- **Onde roda:** CronJob `restic-backup` no k3s (namespace `backup`), às 05:00, depois da réplica local e do dump do Postgres do Immich. Não no NAS, porque:
  - o NAS é configurado só pela UI e o repo nunca altera o NAS;
  - no cluster ficam GitOps, imagem por digest, segredo em KSOPS e alertas no stack existente;
  - o NAS (T400, sistema em USB 2.0) já é frágil.
  - O custo é ler por NFS (`ro`) pela tailnet. Com upload abaixo de 50 Mbps, o gargalo é a internet, não o NFS.
- **Escopo:** a raiz do SSD inteira (export `photos`, PV `backup-source`, só leitura). Isso inclui `data-with-backup`, `data-without-backup` e `immich-data` (uploads e dumps do Postgres).
- **Retenção:**
  - restic: 7 diários, 4 semanais, 6 mensais. O `forget` roda todo dia; o `prune` e o `check --read-data-subset=5%` rodam aos domingos.
  - Snapshots automáticos do Storage Box: 7 diários às 07:00 UTC, antes do backup. Ficam fora do alcance da chave SSH do cluster: se ela for usada para apagar o repositório, dá para voltar até uma semana. Não têm custo à parte, mas ocupam a cota.

## Consequências e riscos

- **Senha do restic:** sem ela o backup é irrecuperável. Guarde-a no gerenciador de senhas (`sops -d kubernetes/workloads/backup/overlays/nas/restic.sops.yaml`).
- **Envio inicial:** leva dias (~3 a 20 Mbps, ~11 a 5 Mbps). Cada execução é cortada em 22h e retomada no dia seguinte. Enquanto isso, o alerta `backup-offsite-stale` dispara.
- **Cota:** com o crescimento do NAS, os snapshots antigos e os snapshots do box, 1 TB pode encher. Siga os gatilhos de upgrade do NAS; o próximo degrau é o BX21. Não há alerta de cota ainda: o espaço usado aparece no painel da Hetzner e no `restic stats`.
- **Arquivos ilegíveis:** com o `all_squash` 1000:100 do export, um arquivo sem permissão de leitura para esse usuário faz o restic sair com código 3. O Job falha e dispara `backup-offsite-failed`, mesmo com o snapshot criado.
- **Cache:** o cache do restic é um `emptyDir`. Cada execução baixa de novo índices e árvores, o que é aceitável com tráfego grátis. Um PVC local-path deixaria a Application `Progressing` até a primeira execução.
- **Restore:** é feito da WSL com o restic e a mesma chave/senha (README). O tráfego de saída do Storage Box não é cobrado.
