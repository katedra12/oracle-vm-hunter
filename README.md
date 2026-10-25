# oracle-vm-hunter

Grabs an Always Free **A1** VM in Oracle Cloud (Frankfurt) for Nora (a
private project) while Oracle is out of capacity, around the clock on GitHub Actions. It does the same job as
Nora's own hunter (`deploy/oci/provision-vm.sh` and `resize-vm.sh` in `nora-oci-hunt.service`
on the owner's PC), which can only run while that PC is on.

## What it does

Every 3 minutes ([hunt.sh](hunt.sh)):

1. **No VM yet:** asks for `nora-prod` in each of Frankfurt's 3 zones, first 2 OCPU / 12 GB,
   then 1 OCPU / 6 GB. "No capacity" is the normal answer.
2. **VM is 1 OCPU / 6 GB:** tries to grow it to 2 / 12 (this reboots it), but only until prod
   moves there. Nora's `cutover.sh` tags the VM `nora-cutover`; after that the PC does the
   resize, because it first checks that nobody is online.
3. **VM is 2 OCPU / 12 GB (or prod moved):** opens an issue and switches the workflow off.

It only creates the VM. The rest (reserved public IP, data volume, setup over SSH) needs the PC
and happens there: `nora-oci-hunt.service` notices the VM, whoever got it.

Success opens an issue that @mentions the owner's main account. A broken hunt (5 unexpected
answers from Oracle in a row) opens one "has a problem" issue and keeps retrying.

Each run hunts ~55 minutes and starts the next one; the `*/30` cron only restarts that chain if
it breaks. The run logs are public, so they show zones and sizes but never IDs. Nora's PC
report (`oracle-vm-attempts.md`) reads them too.

## Secrets

The Oracle user is **`nora-hunter`**: API key only (no console login), group `nora-hunter`,
policy `Nora-Hunter`. It can create and resize VMs in the `nora` compartment and **can't delete
anything**.

| Secret | |
|---|---|
| `OCI_CONFIG` | `[DEFAULT]` with `user`, `fingerprint`, `tenancy`, `region` (no `key_file`) |
| `OCI_KEY` | that user's private API key (PEM) |
| `COMPARTMENT`, `SUBNET`, `NSG` | from Nora's `~/.config/nora-oci/ids.env` |
| `ADS` | the 3 availability domain names, space-separated |
| `VM_SSH_PUB` | Nora's `~/.config/nora-oci/vm_ssh.pub` |

[cloud-init.yaml](cloud-init.yaml) is a copy of Nora's `deploy/oci/cloud-init.yaml`; keep the
two the same.

## Control

- Stop: `gh workflow disable hunt.yml -R katedra12/oracle-vm-hunter`
- Start again: `gh workflow enable hunt.yml -R katedra12/oracle-vm-hunter`, then
  `gh workflow run hunt.yml -R katedra12/oracle-vm-hunter`
- One round on the PC (with the hunter's key): `ONCE=1 ./hunt.sh` with the env from the
  workflow's Hunt step.

GitHub switches a public repo's scheduled workflow off after 60 days without commits, and
with it the whole hunt: commit something at least every 60 days while it's still needed.
