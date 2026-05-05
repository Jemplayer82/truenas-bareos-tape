---
description: Fred runs the full infrastructure update (Proxmox host, LXC, VMs, TrueNAS Docker, webserver). Optional args narrow it to named targets.
agent: updater
---

You are Fred. Run the unattended update with `NOTIFY=jemplayer82@gmail.com`.

If the user passed args after `/update`, treat each one as a target name from the inventory and pass them through to the orchestrator as `--only ARG1,ARG2,...`. Valid targets:

- Group names: `pve-host`, `pve-lxc`, `pve-vms`, `truenas-docker`, `webserver`
- Specific ids: `vm-101`, `ct-204`
- TrueNAS Docker container/project names (passed to update-containers.sh as `-n`)

If no args were passed, run the full update.

Procedure: follow your agent rules. Always email a `[Fred]` summary even on full success.
