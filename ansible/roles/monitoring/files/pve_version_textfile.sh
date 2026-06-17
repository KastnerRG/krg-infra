#!/usr/bin/env bash
# Publish the Proxmox VE version as a node_exporter textfile metric.
#
# The PVE version lives in the pve-manager package (reported by `pveversion`), NOT
# in /etc/os-release — which only carries the Debian base (e.g. "12 / bookworm").
# So the node_exporter `os` collector (node_os_info) cannot see it. This writes a
# node_pve_version{version="..."} sample into the textfile-collector directory.
#
# Installed + scheduled (oneshot + timer) by ansible/roles/monitoring, gated on
# monitoring_pve_version (true only for the proxmox group). Mirrors how the NixOS
# side publishes zpool health via the textfile collector (krg.zfs).
set -euo pipefail

textfile_dir="${1:-/var/lib/node_exporter/textfile}"
out="${textfile_dir}/pve_version.prom"
tmp="$(mktemp "${out}.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

# pveversion line: "pve-manager/8.2.4/<hash> (running kernel: ...)" -> "8.2.4"
version="$(pveversion | head -n1 | sed -E 's#^pve-manager/([^/]+)/.*#\1#')"

printf 'node_pve_version{version="%s"} 1\n' "$version" > "$tmp"
chmod 0644 "$tmp"
# Atomic publish so node_exporter never reads a half-written file.
mv "$tmp" "$out"
