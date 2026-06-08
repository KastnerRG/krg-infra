#!/usr/bin/env bash
# Lint the WHOLE repo — every layer, one command. This is the canonical runner;
# .github/workflows/lint.yml just calls it, so local and CI agree.
#
# Every tool is invoked via `nix run nixpkgs#<tool>` so no host installs are
# needed (you already have nix for the flake). Configs live at the repo root:
#   ruff.toml  .tflint.hcl  .yamllint  .ansible-lint  statix.toml
# Nix *formatting* (alejandra) is gated separately by `nix flake check ./nix`
# (build.yml) — here we run the fast `alejandra --check` proxy plus the semantic
# Nix linters (statix/deadnix) that the flake check does NOT cover.
#
# Runs ALL linters even when one fails, then exits non-zero if any did, so a
# single run surfaces every problem.
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)" || exit 1
cd "$root" || exit 1

fail=0
section() { printf '\n\033[1m=== %s ===\033[0m\n' "$1"; }
run() {
  local name=$1
  shift
  section "$name"
  if "$@"; then echo "ok: $name"; else
    echo "FAIL: $name"
    fail=1
  fi
}

# --- Nix -------------------------------------------------------------------
run "alejandra (Nix format)" bash -c 'cd nix && nix run nixpkgs#alejandra -- --check .'
run "statix (Nix anti-patterns)" bash -c 'cd nix && nix run nixpkgs#statix -- check .'
run "deadnix (dead Nix code)" \
  nix run nixpkgs#deadnix -- --fail --no-lambda-arg --no-lambda-pattern-names nix/

# --- Python (synology apply_*.py, scratch/*.py, drift/) --------------------
run "ruff format" nix run nixpkgs#ruff -- format --check .
run "ruff check" nix run nixpkgs#ruff -- check .

# --- OpenTofu / Terraform --------------------------------------------------
run "tofu fmt" nix run nixpkgs#opentofu -- fmt -check -recursive terraform/
run "tflint" bash -c "cd '$root/terraform' && nix run nixpkgs#tflint -- --recursive --config '$root/.tflint.hcl'"

# --- YAML (non-ansible: spec/, compose, workflows, test rig) ---------------
run "yamllint" nix run nixpkgs#yamllint -- ansible/ spec/ nix/docker-compose/ .github/ test/

# --- Ansible (two self-contained trees, each its own roles_path) -----------
run "ansible-lint (ansible/)" bash -c 'cd ansible && nix run nixpkgs#ansible-lint -- -q --exclude synology'
run "ansible-lint (ansible/synology/)" bash -c 'cd ansible/synology && nix run nixpkgs#ansible-lint -- -q'

# --- Shell -----------------------------------------------------------------
# Note: shfmt is intentionally NOT run as a formatter — it rewrites
# associative-array keys with dashes (`[krg-vault]` -> `[krg - vault]`) and would
# corrupt deploy/deploy-nixos.sh. We keep the linter (below) without that footgun.
mapfile -t sh_files < <(git ls-files '*.sh')
run "shellcheck" nix run nixpkgs#shellcheck -- "${sh_files[@]}"

if [ "$fail" -ne 0 ]; then
  printf '\n\033[1;31mLINT FAILED\033[0m\n'
  exit 1
fi
printf '\n\033[1;32mALL LINT PASSED\033[0m\n'
