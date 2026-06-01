# krg.crowdsecBouncer — CrowdSec → nftables decision applicator.
#
# Thin wrapper over upstream services.crowdsec-firewall-bouncer. Polls
# the local CrowdSec LAPI every 10s for new decisions and updates a
# dynamic nftables ban set; new bans take effect within the next packet
# the affected IP sends.
#
# OWNS its own nftables tables (`crowdsec` for v4, `crowdsec6` for v6).
# Does NOT touch the main nixos-fw table — krg.firewall stays
# uncomplicated. Each crowdsec table has a chain at priority `filter`
# that drops `saddr @crowdsec-blacklists` (or v6 equivalent). Decisions
# are added/removed via `set-only` mode (the bouncer writes to the set;
# the chain reads from it).
#
# AUTHENTICATION: defaults to `registerBouncer.enable = true` (which is
# upstream's default whenever services.crowdsec is enabled, which we
# always pair with the bouncer). The bouncer auto-runs `cscli bouncers
# add` on first activation and stores the API key under
# /var/lib/crowdsec-firewall-bouncer-register/. No operator action
# needed. For a remote LAPI we'd flip to apiKeyPath; not in scope here.
#
# DEPENDENCIES:
#   * krg.crowdsec.enable = true (provides the LAPI to pull from).
#   * networking.nftables.enable = true (krg.firewall.enable=true
#     forces this; assertion-checked below as a safety net).
#
# OBSERVABILITY:
#   * `cscli decisions list`  — current active bans (run as crowdsec user).
#   * `nft list set inet crowdsec crowdsec-blacklists` — what the bouncer
#     pushed to nftables right now.
#   * `journalctl -u crowdsec-firewall-bouncer` — bouncer poll/push.
{ config, lib, ... }:
with lib;
let
  cfg = config.krg.crowdsecBouncer;
in {
  options.krg.crowdsecBouncer = {
    enable = mkEnableOption ''
      CrowdSec firewall bouncer (nftables mode). Applies CrowdSec
      decisions as a dynamic nftables drop set in its own table —
      independent of krg.firewall's nixos-fw rules
    '';
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        # The assertion checks the underlying services.crowdsec.enable
        # (what actually matters for the bouncer to have an LAPI to pull
        # from); the message points at the wrapper option that's the
        # conventional path for THIS repo, plus mentions the direct path
        # so someone bypassing the wrapper isn't misled.
        assertion = config.services.crowdsec.enable;
        message = ''
          krg.crowdsecBouncer requires services.crowdsec.enable = true so
          the bouncer has decisions to pull. THIS wrapper doesn't enable
          services.crowdsec — that's the companion `krg.crowdsec`
          wrapper (the conventional path in this repo). You can also
          enable the upstream service directly if you have a non-default
          LAPI config. Fix one (set `krg.crowdsec.enable = true` or
          `services.crowdsec.enable = true`), or disable
          krg.crowdsecBouncer.
        '';
      }
      {
        assertion = config.networking.nftables.enable;
        message = ''
          krg.crowdsecBouncer requires networking.nftables.enable = true
          (the bouncer manages nftables sets). krg.firewall.enable = true
          forces this; if you've disabled krg.firewall, also disable
          krg.crowdsecBouncer.
        '';
      }
    ];

    # Upstream defaults are exactly what we want:
    #   * mode = "nftables" (auto-set when networking.nftables.enable = true)
    #   * createRulesets = true (owns its own crowdsec/crowdsec6 tables)
    #   * registerBouncer.enable = true (auto-cred via cscli)
    #   * update_frequency = 10s
    # Just toggle it on; per-host overrides go straight to
    # services.crowdsec-firewall-bouncer.* in the host config.
    services.crowdsec-firewall-bouncer.enable = true;
  };
}
