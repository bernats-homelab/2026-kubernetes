# 003 — Máquina de controle remota (WSL) via SSH pela tailnet

- **Status:** aceito
- **Data:** 2026-10-31

## Contexto

O repo é editado numa máquina Windows e o notebook é acessado por OpenSSH pela tailnet. O Ansible não roda nativamente no Windows.

## Decisão

- O Ansible roda no **WSL** e conecta no notebook por SSH, com `become` pedindo a senha do sudo.
- O Tailscale do host é **somente leitura** para o playbook. O role `tailscale_check` lê o status (MagicDNS e IPs para o `tls-san` do k3s) e nunca roda `tailscale up/down`. O hook `no-lockout` impede tasks que alterem Tailscale, SSH, firewall ou rede.
- O inventário real fica fora do git. O nome da tailnet é descoberto em runtime, e o kubeconfig vai para `~/.kube/notebook.yaml` no WSL.

## Consequências

- Reinstalar o notebook do zero exige colocá-lo na tailnet manualmente antes de rodar o playbook.
- Em `/mnt/c`, o `ansible.cfg` só é lido via `ANSIBLE_CONFIG`, que o Makefile exporta.
