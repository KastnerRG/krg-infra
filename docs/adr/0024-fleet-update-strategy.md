# 0024. Fleet update strategy — continuous install, gated activation, alerting as the foundation

**Status:** Proposed · **Date:** 2026-10-21

## Context

The fleet's stated policy is a **quarterly update cycle** (end of each quarter). The last cycle was
missed because nobody had time to run it, and nothing told anyone it had been missed. Two
recent pressures make that cadence look insufficient regardless:

- **The volume of kernel and userland CVEs keeps growing, and AI-assisted discovery and exploit
  development are shrinking the gap between fix and working exploit.** A 90-day floor (180 days
  when a cycle slips) is a long window, especially on hosts where untrusted code meets the kernel:
  waiter (many AD users with shell, public IP), the Docker hosts, and the Incus tenant platform.
- **Container userland is never updated.** The phpshell incident and the recent cert problems are
  both symptoms of stale app-layer software, not of stale kernels.

What actually happens today, per layer:

| Layer | Install | Activate |
|---|---|---|
| NixOS userspace | Nightly: `flake-update.yml` bumps the lock, every host's `system.autoUpgrade` builds + switches at 04:00 (`nix/profiles/base.nix`) | Immediate (services restart on switch) |
| NixOS kernel | Nightly (same path) | **Never automatically**: `allowReboot = false`. Only when a human reboots |
| NixOS release | Manual flake-input bump | Same as above. **26.05 is EOL 2026-12-31** |
| Container images | **Never.** Tags are pinned and nothing bumps them. Floating tags (`traefik:v3.7`, `loki:3.7`, `valkey:9.1`, `postgres:16`) are frozen too: `compose up -d` only pulls *missing* images; only the unit's `ExecReload` runs `pull`, and nothing triggers it | Never |
| fabricant (Proxmox) | `unattended-upgrades` with **Debian-Security origins only**. Proxmox's own packages (kernel, QEMU, `pve-manager`) are not updated at all | Never: `Automatic-Reboot "false"` |
| Incus tenants | Tenant's own flake autoUpgrade (apply); krg-infra pin bump is manual (advance) | Same as NixOS |
| e4e-nas (DSM) | `spec/e4e-nas/dsm-updates.yml`: hotfix-security, auto-install Sun 03:00 | DSM-managed |
| Tooling (tofu providers, GitHub Actions, ansible collections) | Manual | n/a |

And three gaps make activation unsafe to automate today:

1. **There is no alerting at all.** `terraform/grafana/` has dashboards, datasources and SSO,
   but no contact points, notification policies or rules. Grafana has no SMTP, and there is no
   Alertmanager. ADR 0018 §5 ("collection is not monitoring until something pages") was decided
   but never built. Any automation in this ADR would fail silently.
2. **Activation is an outage.** A compose change restarts `krg-prod.service`, which runs
   `compose down` on every lab service. There is no handoff, so a container update is a
   full-stack outage. Service VMs are single instances, so a reboot is an outage. **The lab
   cannot currently absorb automated service-VM reboots.**
3. **OpenBao comes back sealed.** krg-vault uses the default seal (no `seal` stanza; single Raft
   node, OpenBao 2.6.4). After any krg-vault restart, vault-agent renders fail closed and anything
   on krg-prod that restarts can't start until a human unseals. `deploy/reboot-fleet.sh` reboots
   krg-vault *before* krg-prod and checks only `boot_id`, not that OpenBao is unsealed or that
   services are healthy.

Alternatives considered for the kernel and rejected as the primary mechanism:

- **Live kernel update (kexec + Live Update Orchestrator).** LUO (Linux ≥ 6.19, systemd ≥ 262)
  preserves memfd/vfio/iommufd file descriptors across kexec, **not processes**. Every process,
  GPU job and TCP connection still dies. Useful later for VM hosts (QEMU CPR + memfd guest RAM),
  not for this fleet's workloads, and not for waiter's GPU jobs.
- **Kernel livepatch (kpatch).** Keeps running jobs alive and is the right tool for a single
  critical CVE on waiter. But NixOS has no patch producer (Canonical/Red Hat pay teams for this),
  so every patch would be ours to write and validate. Kept as an **emergency-only** option (§2),
  not a cadence.

## Decision

### Principles

1. **Every update is a commit that CD applies** (ADR 0001). No hand-run `apt` or `docker pull`.
   Bots open PRs; humans review exceptions.
2. **Installing an update and activating it are separate steps.** Install continuously. Activation
   (restart or reboot) is either non-disruptive or happens in a scheduled window.
3. **Severity sets the cadence; the calendar is only the slowest acceptable pace.**
4. **How far behind each layer is shows up as a metric and an alert.** A missed cycle must be
   loud.
5. **Everything runs automatically.** Patching, image updates, reboots and announcements all run
   on schedules with no human trigger. A human is needed only for (a) one-time setup steps (the
   OpenBao seal migration, provisioning the Slack credentials) and (b) an approval click on
   upgrades that migrate a database. Steady state costs well under an hour a month.
6. **Nobody is rebooted without warning.** Every reboot is announced in Slack first. On the
   research compute hosts, users can delay it but never cancel it (§3).

### 1. Target per layer

| Layer | Target |
|---|---|
| NixOS userspace | Unchanged (nightly) |
| NixOS release | Upgrade within ~30 days of each release, always before the previous one's EOL. A scheduled workflow detects the new `nixos-YY.MM` branch and opens the bump PR automatically. It goes through PR CI with a full build of every host, never through the nightly job, and merges on an approval click (a release upgrade is a migrating upgrade) |
| Kernels (NixOS) | Monthly window (§4 P4), rebooting only hosts whose running kernel is stale. waiter and kastner-ml reboot at 21:00 and offer self-service Slack delays (§3) |
| Container images | Renovate + digest pins (§4 P2); patch/digest bumps auto-merge and apply via handoff (§4 P1) |
| fabricant | Proxmox packages patched monthly by a scheduled Ansible run in the window (an explicit `dist-upgrade` with checks, not `unattended-upgrades`, which Proxmox advises against); quarterly scheduled reboot. Dissolves at the Incus pivot (ADR 0019) |
| Incus tenants | Renovate on tenant repos bumps the krg-infra pin |
| e4e-nas | Unchanged for hotfixes. Major DSM versions: detected and announced in Slack, applied on an approval click (DSM majors can break the `synology_*` roles' webapi assumptions) |
| Tooling | Renovate, grouped weekly |
| Firmware (BIOS/BMC/NIC/GPU) | Yearly and on vendor advisory; BMCs reachable only from internal networks |
| Endpoints | Out of scope (Fleet MDM, ADR 0012) |

### 2. Response times by severity

| Severity | Time to **activate** (including reboot if needed) |
|---|---|
| Actively exploited (CISA KEV), or critical in an internet-facing service | **72 h**, out of band. Announced in Slack with a countdown; **delays are not accepted**, including on waiter/kastner-ml (§3). A kpatch livepatch on waiter is the option of last resort when even that would be unacceptable |
| Other critical / high | **14 days** |
| Everything else | Next monthly window |

### 3. Windows

- **Monthly window** for fleet reboots (replaces quarterly). Proposed: first Sunday of the month,
  05:00 local, after the 04:00 autoUpgrade has landed.
- **Service hosts** (krg-prod, e4e-prod, krg-ldap, krg-vault, krg-nat, krg-deploy, tenants):
  rebooted in the window, announced in Slack beforehand, no delays.
- **fabricant**: quarterly, in the window, announced, all guests down. Unavoidable on a
  single-node hypervisor.
- **Research compute (waiter, kastner-ml): self-service delays from Slack.** The goal is to let
  a researcher say *"oops, I have something running, let it finish first"* without asking an
  admin, while asking for no more delay than the job actually needs. A long default delay would
  just invite more long jobs to be started. So every announcement offers a menu of delays, and
  the shortest one that covers the job is the natural pick:
  1. When a host's kernel is stale, the scheduler posts **one week before** its window to that
     host's announcement channel, in the host's own Slack workspace (§4 P0): *"waiter will
     reboot at \<time\> for kernel updates. If you need it to wait, react with how long."* The
     message lists one emoji per available delay, and the bot pre-adds each one as a reaction
     so people only have to click. The bot's own reactions don't count.
  2. **Delay menu.** The first announcement offers **1 month, 14 days, 7 days, 4 days, 2 days
     and 1 day**. Each delay removes the longest remaining option, regardless of which option
     was picked: after the first delay, **14d / 7d / 4d / 2d / 1d**; after the second,
     **7d / 4d / 2d / 1d**; and so on down to **1d** only, which stays available indefinitely.
  3. **Delays are evaluated only at the moment the host would otherwise reboot.** Until then,
     reactions are just requests and can be added or removed freely (react "2 days", then remove
     it if the job finishes early). At the scheduled time:
     - **No reactions** (other than the bot's): the host reboots.
     - **Otherwise the largest delay anyone selected wins.** The scheduler pushes the reboot out
       by that amount and posts a new announcement with the new time and the next, shorter
       menu.
  4. **Reboots always happen at 21:00 local**, in the evening, so a day's work can finish and
     an overnight job can start after the reboot. The first reboot is on the monthly window's
     day. Every computed time rounds **up** to the next 21:00, never earlier. The 1-month option moves
     the reboot to the same time in the following month's window. A pending reboot keeps its
     place in the menu sequence when that next window arrives; it doesn't start over.
  5. **A reboot can be delayed indefinitely, one day at a time, but never cancelled.** There is
     no cancel option. If someone reboots the host by hand onto the current kernel in the
     meantime, the pending reboot is complete.
  6. **Day-of reminder:** on the day of the reboot (morning, e.g. 09:00), if the last message
     about this reboot was posted **more than a day ago**, the scheduler posts a reminder in the
     announcement's thread. The reminder shows which delays are currently selected, and the
     menu stays open until 21:00. After a 1-day delay, the announcement itself went out the
     evening before, so no day-of reminder is sent. **Every reboot also gets a reminder 1 hour
     before** (20:00), with the currently selected delays. The result (rebooted / health check
     passed / failed) is posted after.
  7. The menu resets to the full set after each successful reboot.
  8. **Emergency reboots (§2) don't follow any of this.** They aren't tied to the window's time
     of day: they post an announcement with "delays not accepted", offer no menu, and reboot
     **the same day** after the minimum notice (§4 P4).

  Users should still checkpoint long jobs; that protects against OOM kills and hardware faults
  too, not just reboots.

### 4. Work packages (in order; each ships default-off per "merging is applying")

**P0: Alerting foundation (prerequisite for everything else).**

- Grafana-managed alerting in `terraform/grafana/` (`grafana_contact_point`,
  `grafana_notification_policy`, `grafana_rule_group`), not a separate Alertmanager. Rules live in
  git.
- **Delivery: Slack, in two workspaces (KRG and E4E).** The fleet serves both groups, and each
  needs its own hosts' alerts and reboot announcements.
  - **One Slack app per workspace**, used by both Grafana and the reboot scheduler (P4). This
    avoids publicly distributing a single app. Each needs a bot token with `chat:write`,
    `reactions:read` and `channels:history`; an incoming webhook can't read reactions, so a bot
    token is required anyway.
  - Tokens are stored in OpenBao, one path per workspace (`…/slack/krg`, `…/slack/e4e`), and
    read by `terraform/grafana` the same way it reads `grafana-oidc` (`sso.tf`) and by the
    scheduler via vault-agent.
  - **Ownership is a label.** Every Prometheus target carries `org="krg"|"e4e"`, set from one
    host→org map in the repo (E4E today: e4e-prod, kastner-ml, e4e-nas, and the E4E tenants;
    everything else KRG). Grafana has one Slack contact point per workspace, and the
    notification policy routes on `org`. The reboot scheduler reads the same map to pick a
    workspace and channel per host.
  - **Fleet-level alerts** (dead-man's switch, OpenBao sealed, krg-prod down, deploy pipeline)
    affect both groups' services, so they go to **both** workspaces' admin channels.
  - Each contact point lands only once its secret exists in OpenBao, so one workspace can go live
    before the other. Rules and policies can land earlier (they're harmless with no receiver).
- Starter rules:

  | Rule | Source |
  |---|---|
  | Host down | Prometheus `up == 0` |
  | TLS cert expires < 14 days | blackbox `probe_ssl_earliest_cert_expiry` (cf. the 2026-08-17 cert-expiry outage, ADR 0021) |
  | Disk > 85%, ZFS pool degraded | node-exporter (waiter's scratch pool has no redundancy) |
  | A systemd unit failed | node-exporter systemd collector (`nixos-upgrade`, compose stacks, vault-agent) |
  | OpenBao sealed | OpenBao telemetry (enable `telemetry` on krg-vault) |
  | Kernel stale: running ≠ installed **and** uptime > 35 days | textfile metric (compare `/run/booted-system/kernel` with `/run/current-system/kernel`) + `node_boot_time_seconds`; on fabricant, `uname -r` vs the newest installed kernel |
  | NixOS release within 45 days of EOL | textfile metric derived from `system.nixos.release` |
  | Image CVEs | Trivy report (after P2) |

- **Dead-man's switch.** Grafana runs on krg-prod; if krg-prod is down, nothing alerts. A
  scheduled GitHub-hosted workflow probes `monitoring.krg.ucsd.edu/api/health` (and krg-prod
  reachability) from off-site and posts to Slack on failure.
- **Tune before trusting.** Run the rules for a week to a quiet channel and fix false positives.
  Alert fatigue would undo this as surely as having no alerts.

**P1: Compose graceful handoff.**

- `nix/modules/services/compose-stack.nix`: a compose change **reloads** the unit instead of
  restarting it (`restartIfChanged = false` + `reloadIfChanged`/`reloadTriggers`), so no
  `compose down` of the whole stack.
- Per-service policy label `krg.rollout: handoff | restart` (default `restart`). The reload
  script compares each service's `docker compose config --hash` with the running container's
  hash label and acts only on changed services:
  - `handoff`: [`docker-rollout`](https://github.com/wowu/docker-rollout) (MIT, single script;
    packaged in-repo) starts a second container, waits for its healthcheck, stops the old one
    (Traefik routes to both while they overlap, then drops the old one), and removes it.
    **If the new container never becomes healthy, it is removed, the old one keeps serving, and
    the unit fails loudly.**
  - `restart`: `up -d --no-deps <svc>`.
- Requirements for `handoff`: no `container_name`, no host `ports:`, a healthcheck, clean SIGTERM
  shutdown, and **old + new versions able to share the database schema**. Digest and patch bumps
  qualify; minor/major bumps that migrate (Authentik, Fleet's `fleet_migrate`, Outline) take
  the `restart` path, with the migration run first.
- krg-prod tiering:

  | Tier | Services |
  |---|---|
  | Handoff | `authentik_server`, `authentik_proxy`, `outline`, `fleet`, `mlflow`, `guacamole`, `temporal-ui` (drop `container_name` where set; add healthchecks) |
  | Handoff after P6 | `grafana`, `vaultwarden` (SQLite today) |
  | Fast restart | Postgres/MySQL/Valkey, `prometheus`, `loki`, `temporal`, `authentik_ldap` (389/636), `guacd`, `authentik_worker`, `alloy`, exporters. Dependents gate on `depends_on: condition: service_healthy` |
  | Restart in window | `traefik` (owns 80/443) |

- Pilot on `temporal-ui` / `mlflow` under a timed request loop before widening. Tenant stacks
  inherit the mechanism.

**P2: Renovate.**

- Repo-wide: compose images (docker-compose manager, plus a regex manager for images referenced
  from `.nix`), tofu provider locks, GitHub Actions, ansible collections. Also on tenant repos,
  for their krg-infra pin.
- Images pinned `tag@sha256:digest`, so upstream rebuilds on a patched base surface as PRs.
- **Patch and digest bumps auto-merge.** For `handoff` services, as soon as CI passes. For
  `restart`-tier services (databases, Prometheus, Traefik), Renovate's `schedule` holds them so
  they merge at the start of the monthly window and their seconds-long restart lands there.
  **Minor/major bumps that migrate a database wait for an approval click** (with a Slack ping);
  everything else auto-merges.
- The existing lint check that every referenced image tag exists (`scripts/lint.sh`) gates
  Renovate PRs as-is. Extend it to verify digests once images are digest-pinned.
- Batch updates. An auto-merge storm can still hit Docker Hub's anonymous pull limit (it has
  taken a deploy red once). The `mirror.gcr.io` registry mirror (#470) absorbs most of this;
  authenticated pulls are the fallback if batching isn't enough.
- Trivy scan of the referenced image set, reported as metrics for the P0 rule.

**P3: OpenBao auto-unseal, deferred until after the Proxmox→Incus pivot (ADR 0019).**

- Deferred by decision (2026-10-21) so no Proxmox-specific seal plumbing (SMBIOS credentials and
  the like) gets built only to be deleted at the pivot
  (cf. "no new Debian-era services on fabricant").
- Planned shape after the pivot: **static key seal, key held on the hypervisor** (systemd-creds,
  ideally sealed to the host TPM), passed to krg-vault through a read-only Incus disk device, so a
  stolen VM disk or backup alone is not enough. Boot order (krg-vault before its consumers) goes
  in `terraform/incus` via `boot.autostart.priority`. Recovery keys go in the admin-only
  Vaultwarden.
- Moving from the default seal is a one-time **seal migration** (`bao operator unseal -migrate`)
  performed by an operator in a planned window. The config change and the migration land together,
  never as an unattended CD apply.
- **Until then, krg-vault restarts need a human to unseal.** So before P3: the 26.11 upgrade's
  reboots (§1) and every krg-vault or fabricant reboot are **scheduled and announced but staffed**.
  The scheduler pauses after rebooting them until the health check sees OpenBao unsealed, and
  pings the admin channel to unseal. Hosts that don't depend on a fresh unseal (krg-nat, waiter,
  kastner-ml, e4e-prod, unless krg-vault restarted too) can be fully automatic before P3.
- **Related fix that does not wait for the pivot:** `openbao-agent` on krg-prod is a no-retry
  oneshot. On a cold start where krg-prod comes up before krg-vault is unsealed, the lab stack
  stays down until someone restarts it. Making the agent retry until OpenBao is unsealed belongs
  in P1's timeframe, since it's what makes "unseal, then everything recovers by itself" true.
- Check seal packaging before bumping OpenBao: 2.7 moves several built-in mechanisms to plugins.

**P4: Reboot scheduler (automatic windows + self-service Slack delays).**

- A NixOS module on **krg-deploy** (the control node), e.g. `krg.rebootScheduler`: a Python
  service on a ~10-minute systemd timer, in the same researcher-maintainable style as
  `modules/scratch/*.py`. It **polls Slack** (`reactions.get`) instead of receiving Slack events,
  so there's no inbound endpoint to expose or secure.
- State per host (scheduled time, number of delays so far, current announcement `ts`, time of
  the last message, emergency flag) is a
  JSON file under `/var/lib/krg-reboot-scheduler/` on krg-deploy's persistent storage. Slack
  is the UI only; the scheduler never derives state from message history.
- Each tick:
  1. Read which hosts are stale (the P0 kernel-staleness metric, from Prometheus).
  2. Schedule stale hosts for their next window and post announcements (§3) **one week ahead**,
     to the host's workspace and channel per the host→org map (P0).
  3. Post the day-of and 1-hour reminders when they're due (§3 item 6).
  4. At a host's scheduled time, read the current announcement's reactions (ignoring the bot's
     own). If someone selected a delay, apply the **largest** one, rounded up to 21:00 for
     waiter/kastner-ml, and post the next announcement with the shorter menu (§3 items 2–4).
     Otherwise, reboot via `deploy/reboot-fleet.sh <host>` (reusing its SSH identity and
     boot-id check), then run the health check and post the result.
- **Health check** after each host, not just `boot_id`: OpenBao unsealed, compose units active,
  key endpoints healthy. A failure stops the window, so later hosts stay up, and posts to Slack.
- **Fail safe:** if the announcement can't be posted (Slack down, token revoked), the reboot does
  not happen and the scheduler alerts. Nobody is rebooted unannounced. The kernel-staleness
  alert still fires if this persists.
- **Emergency trigger:** a commit setting `emergency = true` for a host (or the whole fleet) in
  the scheduler config. CD applies it, and the scheduler posts a no-delay announcement and reboots
  **the same day**, after a short minimum notice (configurable, default 4 h) and with a reminder
  1 h before. Deciding that a CVE is emergency-class is the one judgment call; everything after
  that commit is automatic.
- **Order and coupling:** until P3, fabricant and krg-vault reboots are staffed (P3: the
  scheduler waits for a human unseal and pings for it). krg-vault and krg-ldap reboot in separate
  windows, never alongside each other or krg-prod. krg-deploy runs the scheduler, so it reboots itself last, from a transient
  systemd timer, and the next tick confirms it came back (closing #181's krg-deploy half).
- **Rollout:** ships disabled; enabled host by host after P1, starting with krg-nat, then
  waiter and kastner-ml. krg-prod and e4e-prod follow. krg-vault and fabricant run staffed
  until P3. `reboot-fleet.yml` stays as the manual path.

**P5: fabricant.** A scheduled Ansible patch run in the monthly window: `apt dist-upgrade`
including the Proxmox repository, refusing to proceed if a Proxmox package would be *removed*
(the classic broken-repo failure mode), with the result posted to Slack. Running VMs keep their
old QEMU until restarted, so updating packages while guests run is safe. The quarterly reboot
goes through the P4 scheduler (announced, no delays), staffed for the unseal until the pivot.
Build nothing more; the Incus pivot replaces it.

**P6: Grafana and Vaultwarden → Postgres.** Makes them eligible for handoff. Each is a data
migration in its own planned PR.

### 5. Steady-state operation

Nothing needs a human trigger. The remaining human work:

- **Approving Renovate PRs that migrate a database** (minor/major bumps of Authentik, Outline,
  Fleet, Postgres majors and the like). The scheduler posts to Slack when one is waiting. Patch
  and digest bumps auto-merge.
- **Responding to red alerts**, including a failed post-reboot health check.
- **Declaring an emergency** (§2, one commit).
- **Until P3 (after the Incus pivot): unsealing krg-vault** when the scheduler pings after a
  krg-vault or fabricant reboot.

A rotating admin owns these. Expected cost: well under an hour a month.

## Consequences

- **The kernel staleness window drops from 90–180 days to ≤ ~35 days** on NixOS hosts once P4 is
  live, and from "never" to days for container images.
- **Alerting becomes a dependency of the update path.** If Slack or Grafana is down, so is the
  safety net; the dead-man's switch covers the Grafana half.
- **Handoff is not universal.** Stateful single-writers and Traefik still see seconds of
  interruption, so they update in windows or rarely. Making krg-prod, krg-vault and krg-ldap
  reboots invisible needs HA (a second DC, a 3-node OpenBao Raft cluster, redundant ingress),
  which is **deferred** to its own ADR.
- **Auto-unseal trades away protection against someone holding both the disk and the
  key-delivery path.** It is accepted because availability is the binding constraint.
- **Renovate PR volume** is kept manageable by grouping and auto-merge. Only migrating
  upgrades reach a human.
- **waiter and kastner-ml can stay on an old kernel indefinitely** if someone delays every
  day. That's a deliberate choice: reboots there are never forced outside an emergency. The
  costs are visible rather than hidden: the kernel-staleness alert keeps firing, and every
  delay is a public Slack reaction. The emergency tier (§2, no delays) is the backstop for
  serious CVEs.
- **A Slack outage pauses reboots**, by design (fail safe, §4 P4).
- **Scheduled outages are now automatic.** Service-host windows take services down on schedule
  without a human present. This is acceptable only after P1 (handoff) and the openbao-agent
  retry fix. Hosts whose reboot needs a fresh unseal (krg-vault, fabricant) stay staffed until P3,
  which waits for the Incus pivot.

## Open questions

1. **Monthly window:** is first Sunday 05:00 right for the lab? (Affects the krg-prod outage of the
   restart tier and Traefik.)
2. **Emergency minimum notice:** is 4 hours the right floor for a same-day emergency reboot?
3. **Slack channels, per workspace:** one channel for everything, or an admin alerts channel plus
   a separate reboot-announcement channel (so researchers can follow those without the alert
   noise), plus a critical channel (host down, OpenBao sealed, dead-man's switch) with mobile
   notifications on? Same layout in both workspaces?
4. **Update owner rotation:** who is on the rota?
5. **Severity source:** do we subscribe to CISA KEV and nixpkgs security advisories in Slack, so
   §2's 72-hour clock has a starting signal?
6. **Host ownership:** is the KRG/E4E split in §4 P0 right? In particular, waiter → KRG and
   kastner-ml → E4E, and do any KRG-workspace users also run jobs on kastner-ml (or E4E users on
   waiter) and need announcements in both?
7. **Renovate approval pings:** krg-infra's migrating upgrades affect both groups' services.
   Ping both workspaces, or only KRG's?
8. **Delay emoji:** custom emoji per option (e.g. `:delay-1mo:` … `:delay-1d:`, added once in
   each workspace), or standard emoji with a legend in the message? Custom emoji are clearer
   to click but are a one-time setup step in both workspaces.

## Related

[ADR 0001](0001-iac-source-of-truth.md) (git is truth),
[ADR 0011](0011-cross-layer-deploy-ordering.md) (staged deploy; why an early red blocks later phases),
[ADR 0015](0015-fleet-wide-container-logs-loki.md) (log alerting is out of its scope; this ADR adds metric alerting),
[ADR 0018](0018-monitoring-long-running-vms.md) §5 (alerting decided, delivered here),
[ADR 0019](0019-proxmox-to-incus-migration.md) (retires P5),
[ADR 0021](0021-tenant-tls-vault-agent-and-secret-zero.md) (secret-zero; the cert-expiry outage),
issue #181 (reboot-fleet coverage of krg-deploy and fabricant).
