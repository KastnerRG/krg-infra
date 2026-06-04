# Scheduled tasks (Control Panel -> Task Scheduler) as code.
#
# `synology_core_event` (event-/cron-triggered tasks) is handy for jobs DSM has
# no first-class resource for — e.g. exporting the config backup, cert renewal
# hooks, or kicking a Hyper Backup. NOTE: snapshot *schedules* themselves are
# DSM UI settings (see docs/e4e-nas-dsm.md), not a TF resource.
# Docs: https://registry.terraform.io/providers/synology-community/synology/latest/docs/resources/core_event
#
# Live 2026-05-28 pre-reset capture (archived locally, off-repo):
#   user-visible tasks via `synowebapi SYNO.Core.TaskScheduler list`:
#     id 6   Recycle Bin            type=recycle  enabled  daily 00:00  "Empty all Recycle Bins"  ← REPRODUCE
#     id 3   Auto S.M.A.R.T. Test   type=custom   enabled  monthly                                  DSM-default, skip
#     id 80322000  PowerOff task 0  type=power    disabled one-off                                  stale, drop
#   plus DSM-default system tasks (DSM Auto Update, Security Advisor, Security Scan) that
#   DSM recreates on install — no IaC needed.
#
# TODO: verify the provider's `synology_core_event` attribute names against its registry
# docs and convert the Recycle Bin task below into a working resource.

# resource "synology_core_event" "recycle_bin_clean" {
#   # The single user-config scheduled task on e4e-nas (captured 2026-05-28).
#   # name = "Recycle Bin"
#   # task type "recycle" (Empty all Recycle Bins) — daily 00:00, owner=root, enabled.
#   # Equivalent shell action: `/usr/syno/bin/synocli --recycle-bin --clean`
# }

# ---------------------------------------------------------------------------
# Periodic DSM config-backup export (.dss) — runbook §7 "automate via a
# synology_core_event scheduled task if desired".
#
# The .dss IS the config-as-artifact source-of-truth for the parts no API
# touches (display order, package metadata, etc.). Scheduling an automatic
# export means a fresh DR artifact is always available. Weekly cadence, off-hours.
#
# Destination MUST be off-box and MUST NOT be in this repo — the .dss can
# contain hashed credentials + PII. Per memory rule `krg-infra-no-live-captures`
# and `*.dss` is gitignored under terraform/. Options:
#   (a) Hyper Backup target on krg-prod (NFS path) — simplest, no extra creds.
#   (b) S3 (Garage) bucket once Garage is up — needs a key.
#   (c) External NAS via Hyper Backup destination.
# Open decision in plan.md.
#
# variable "dss_dest_path" {} below; set in terraform.tfvars (untracked).
# ---------------------------------------------------------------------------

# variable "dss_dest_path" {
#   description = "Off-box destination for the weekly DSM .dss export (e.g. /mnt/krg-prod-backup/e4e-nas/configs)."
#   type        = string
# }
#
# Forward direction (consistent with the rest of this workspace, once we
# wire the synology provider's credentials through OpenBao too): read this
# from OpenBao at `secret/e4e-nas/config-backup/destination`, matching the
# pattern terraform/grafana/providers.tf uses:
#
#   data "vault_kv_secret_v2" "config_backup_dest" {
#     mount = "secret"
#     name  = "e4e-nas/config-backup/destination"
#   }
#   locals { dss_dest_path = data.vault_kv_secret_v2.config_backup_dest.data["path"] }
#
# That waits on (a) the `e4e-nas` AppRole + policy landing in
# terraform/openbao/main.tf and (b) deciding the off-box destination (open
# decision: Hyper Backup target on krg-prod NFS? Garage S3 once it stands
# up? external NAS?).

# resource "synology_core_event" "weekly_config_backup_export" {
#   # Provider attribute names — verify against the registry docs before un-commenting.
#   # name       = "krg-config-backup-weekly"
#   # type       = "custom"             # scripted task
#   # owner      = "root"
#   # enabled    = true
#   # schedule {
#   #   weekly  = true
#   #   day     = "Sunday"
#   #   hour    = 2
#   #   minute  = 30
#   # }
#   # # Action: export the .dss to the off-box destination. The DSM-side command
#   # # form for the export is what synowebapi.SYNO.Core.ConfigBackup invokes —
#   # # using the supported CLI wrapper keeps this simpler than calling synowebapi
#   # # from a shell task. Verify on the rig:
#   # script = <<-EOT
#   #   set -euo pipefail
#   #   DEST="${var.dss_dest_path}"
#   #   DATE=$(date +%Y%m%d-%H%M%S)
#   #   FNAME="e4e-nas-config-$${DATE}.dss"
#   #   /usr/syno/bin/synoconfbkp export --filepath "$DEST/$FNAME"
#   #   # rotate: keep the most recent 12 (~3 months at weekly cadence)
#   #   ls -1t "$DEST"/e4e-nas-config-*.dss 2>/dev/null | tail -n +13 | xargs -r rm -f
#   # EOT
# }
