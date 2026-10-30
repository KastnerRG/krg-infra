# Claude extension incident triage and egress blocker

Source: [OpenSourceMalware report](https://opensourcemalware.com/blog/trojanized-claude-code-extension-plants-persistent-ssh-backdoor).
The report identifies a malicious Open VSX artifact claiming
`anthropic.claude-code@2.1.313`; it does not establish that every distribution of
that version is malicious. Version matches are triage findings, not proof.

## Read-only scanning

Run from the repository root with Python 3.8+:

```bash
python3 security/claude-extension/scan.py
sudo python3 security/claude-extension/scan.py
python3 security/claude-extension/fleet.py --identity "$HOME/.ssh/id_ed25519"
python3 security/claude-extension/tenants.py --known-hosts /path/to/verified-known-hosts
```

`scan.py --home /path/to/home` is repeatable to restrict scope. Default homes
include local users, `/home`, `/local`, the fabricant NFS home export, and DSM
local and nested domain homes. Remote IDE root symlinks into `/local` are handled.
The scanner looks for the attacker key (independent of its comment), C2 address,
known hashes, reported extension version, persistence files, cron/systemd files,
IDE logs, process/socket evidence and recent SSH journal entries. It excludes its
own process ancestry, whose launch commands may contain the indicators.

Reports expose paths and indicator names, not key contents, environment variables
or full process command lines. Exit codes: 0 = no matches or recorded gaps;
1 = findings; 2 = coverage gaps. These are targeted checks, not forensic clearance.
Missing files are not evidence of historical absence. Deleted extensions, custom
IDE roots, rotated logs, arbitrary payloads and container interiors need further
investigation when exposure is suspected. `/proc` and process tools see only the
execution namespace. DSM does not provide the Linux journal or necessarily `ss`.

`fleet.py` uses existing SSH credentials, strict host-key verification and no agent
forwarding; default identity is `~/.ssh/id_ed25519`. It uses `krg-admin`, with the
repository's `e4e-admin` exceptions for E4E hosts. `--hosts`, `--known-hosts`,
`--identity` and `--jump` can scope or route probes. Python is located in the
existing Nix store when absent from the remote PATH. No remote files are written.
Fleet scans do not enter tenants; `tenants.py` enumerates all Incus projects and
executes the same scanner in each running instance through trusted `krg-nat` SSH.

Host keys absent from the laptop can be obtained through an already trusted
management channel. During this investigation, the NAS key came from krg-deploy's
known_hosts and the e4e-prod/krg-nat public keys came through fabricant's QEMU guest
agent. Do not substitute unverified `ssh-keyscan` output or disable checking.

## Blocker (enabled in fleet configuration; deployment pending)

The report recommends blocking `134.209.82.225` on TCP 22 and 8099. The blocker is
limited to those destinations and ports. It does not detect future C2 addresses,
prevent extension execution, revoke credentials, or remove an existing compromise.

* NixOS: `nix/modules/security/malware-egress.nix`, imported by `profiles/base.nix`.
  Set `krg.malwareEgress.enable = true` in the intended host configuration after
  canary review. A dedicated `inet` table drops matching OUTPUT and routed FORWARD
  traffic, including NAT-routed tenant/container egress. Pure bridge switching is
  outside this table's scope. Existing unrelated firewall tables are untouched.
* Proxmox: set `proxmox_malware_egress_enabled: true` in managed inventory after
  canary review. Two OUT rules are rendered into datacenter `cluster.fw`; these
  cover the hypervisor's own traffic. They do **not** claim guest coverage.
  Guests need their NixOS module enabled; appliance and bridged guest egress
  require a separate supported control.
* `block.nft` is a standalone review/canary ruleset for Linux. Syntax check only:
  `sudo nft --check --file security/claude-extension/block.nft`. Do not flush the
  existing ruleset. This file is not persistent configuration for an unmanaged
  laptop; choose its host firewall's persistence mechanism before activation.

The reusable switches default off. Following the read-only canary syntax check,
the eight managed NixOS hosts explicitly enable their switch, and Proxmox inventory
enables its host rules. The golden image remains opt-in; existing tenants are
covered at krg-nat's routed FORWARD hook. No live firewall changes were made. Deployment still follows IaC and release
control. Disabling the Nix option or Ansible flag and reapplying rolls back its
managed rules. For a manually loaded standalone table, rollback is
`sudo nft delete table inet krg_malware_egress`.

Validation performed: detection tests (key with renamed comment, redirected IDE
server, version/persistence indicators, clean older version); Python compilation;
Alejandra and Nix syntax checks; enabled/disabled Nix module evaluation for all nine
configurations with no failed assertions; Proxmox template rendering with its flag
both off and on; `nft --check` on waiter. No full NixOS system builds or live
canary activation have been performed.

If a matching implant is found, preserve evidence before removal, isolate the host,
and rotate account-accessible credentials from a known-clean system. Follow-on
interactive SSH activity may exceed the visible implant; the report recommends
rebuilding exposed hosts rather than trusting removal alone.
