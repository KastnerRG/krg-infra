# Incident triage — 2026-10-30 (America/Los_Angeles)

No matching indicators were found in the targeted checks. This is a point-in-time
IOC assessment, not a declaration that every machine is safe or a full forensic
investigation.

Source: [OpenSourceMalware's Claude extension report](https://opensourcemalware.com/blog/trojanized-claude-code-extension-plants-persistent-ssh-backdoor).
The report identifies a malicious Open VSX artifact claiming version 2.1.313.
Scans checked the reported attacker public key and comment, C2, persistence paths,
file hashes, extension version, and available process/socket/SSH-log evidence.

| Scope | Result | Material coverage limitations |
|---|---|---|
| Laptop user files | No matches; installed extension is 2.1.312 | Root home and root-owned cron inaccessible; sudo requires interactive authentication. Process/network probes are limited by the execution environment. |
| fabricant | No matches | NFS user homes also inspected from the compute hosts; no full disk/history investigation. |
| waiter | No matches | Includes mounted NFS homes and node-local IDE servers. |
| kastner-ml | No matches | Includes mounted user homes and node-local IDE servers. |
| krg-ldap | No matches | Targeted live artifacts and available recent SSH logs. |
| krg-vault | No matches | Targeted live artifacts and available recent SSH logs. |
| krg-deploy | No matches | Targeted live artifacts and available recent SSH logs. |
| krg-prod | No matches | Docker container interiors were not individually scanned. Host and mounted user artifacts were checked. |
| e4e-prod | No matches | Targeted host artifacts; no full application-data investigation. |
| krg-nat | No matches | Its three running tenant VMs were scanned separately. |
| e4e-nas | No matches | Includes 367 enumerated local/domain-home paths (some aliases). `ss` is absent and the SSH journal probe is unsupported; no claim of complete DSM network/log coverage. |
| fishsense tenant VM | No matches | Root-level scan via Incus guest execution. |
| reference-manager tenant VM | No matches | Root-level scan via Incus guest execution. |
| e4e-website tenant VM | No matches | Root-level scan via Incus guest execution; guest reports hostname krg-golden. |

Remote scans ran as root through existing noninteractive sudo or Incus guest
execution. Host-key verification stayed strict. Missing host keys were read from
the trusted deploy host or trusted Proxmox guest agent, without accepting arbitrary
network keys. No private keys or credentials were copied to the remote hosts.

Initial journal timeouts were followed up with targeted queries on all affected
Linux fleet hosts. Those follow-ups completed with no matching lines. `journalctl`
returns 1 for no grep matches; the scanner now handles that as an empty result.
The independent NAS/laptop limitations above remain.

The local KRG source-tree IOC search matched only the newly added blocker files.
No reported extension version 2.1.313 was found in the checked extension locations.
Older versions found on compute hosts ranged from 2.1.183 to 2.1.311. Older version
numbers are inventory evidence, not independent proof of artifact integrity.

## Rollout change

The PR enables a narrow outbound block to 134.209.82.225 TCP ports 22 and 8099 on
all eight deployed NixOS configurations and on the Proxmox host. NixOS OUTPUT and
routed FORWARD hooks also cover Docker/NAT-routed workload egress; krg-nat supplies
the tenant egress control. The reusable module defaults off and the undeployed
golden image is unchanged. The Proxmox rule does not independently cover guests.

The unmanaged laptop and NAS are **not** given persistent outbound blocking by
this PR. A standalone Linux nftables candidate is provided for laptop integration;
NAS egress needs an appropriate upstream or DSM-supported control. The change is
an IOC-specific mitigation, not an extension execution or credential-theft policy.

Validated: three detection tests; Python compilation; Nix formatting/syntax;
all nine Nix configurations evaluated (eight enabled, golden disabled) with no
failed assertions; Proxmox template enabled/disabled rendering; and read-only
`nft --check` against waiter's live kernel. No full system build, live firewall
activation, credential rotation, extension removal or reboot was performed.
Normal CI and deployment must still complete successfully after merge; there is
no guarantee of an overnight rollout until those runs are green.

Raw scan evidence is retained locally under `/tmp/krg-incident-2026-10-30/`; it is
not committed because it contains user-home inventories. Preserve that directory
elsewhere if longer retention is needed. If exposure is established later, isolate
and preserve the host before removal, investigate follow-on SSH access, and rotate
accessible credentials from a known-clean system.
