# 010 — Atualizações do SO do notebook sob controle

- **Status:** aceito
- **Data:** 2026-11-11

## Contexto

Em 2026-11-11, às 06:40, o `apt-daily-upgrade.timer` do Ubuntu disparou num horário aleatório (06:00 + até 60 min) e o unattended-upgrades instalou o kernel 7.0.0-43, com initramfs e módulos NVIDIA. O SSD do notebook é um SATA de entrada (115 GB, 76% cheio): ficou 84% ocupado gravando só 3–8 MB/s. Os dois SQLite do cluster travaram por ~7 min:

- **Grafana:** `database is locked (SQLITE_BUSY)`, com falhas de login, de leitura de datasources e do sync das regras de alerta.
- **k3s (kine):** `Handler timeout` no apiserver.

Nenhum pod reiniciou, mas o kernel novo ficou instalado para o próximo boot sem teste. Foi assim que o 7.0.0-42 (também via unattended-upgrades) quebrou o Postgres em 2026-11-05, pela regressão do AppArmor (memória `kernel-42-apparmor-signals`).

## Decisão

- **Role `os_updates`** (Ansible, depois do `base`):
  - O unattended-upgrades continua instalando atualizações de segurança, **exceto `linux-*`** (`Package-Blacklist`), e não remove kernels antigos sozinho.
  - Horário fixo e sem atraso aleatório: download às 05:00, upgrade às 05:15. Fica depois do rsync do NAS (03:00) e fora do uso.
  - O `apt-daily-upgrade.service` roda com `Nice=19`, `CPUSchedulingPolicy=idle` e `IOSchedulingClass=idle`. O dpkg herda isso, e o `mq-deadline` respeita a classe de I/O.
- **`make kernel-upgrade`** (`ansible/kernel-upgrade.yaml`): instala os `linux-*` pendentes, reinicia se o kernel mais novo em `/boot` não é o que está rodando, e confere kernel, nó `Ready`, todas as Applications Synced/Healthy, Postgres (CNPG) prontos e nenhuma negação do AppArmor de sinal ou D-Bus. Só então roda `apt autoremove`, que mantém o kernel atual e o anterior.
- **Grafana com SQLite em WAL** (`database.wal: true`): leitores não esperam as escritas.
- **GC de imagens do kubelet fica no padrão (85/80).** Testamos 70/60: o kubelet mede o filesystem inteiro (77%, puxado por `/home/snap`, swap e snapd), e as 35 imagens do containerd (18 GB) estão todas em uso. Ele liberou 0 bytes e passaria a registrar falha a cada 5 minutos. O espaço a recuperar está fora do cluster.
- **Alerta `host-disk-saturated`** (warning): disco do notebook mais de 70% ocupado por 5 min.

## Consequências

- Kernel novo só entra quando alguém roda `make kernel-upgrade`. É preciso lembrar de rodar periodicamente (os avisos de segurança do kernel não se aplicam sozinhos).
- O reboot do `make kernel-upgrade` deixa os apps alguns minutos fora; rodar num horário escolhido.
- Postgres do Grafana (em vez de SQLite) e troca do SSD por um maior ficam como alternativas se o problema voltar.
