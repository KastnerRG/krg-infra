# e4e-website (Incus tenant, the E4E website publish agent): the SSH keypair it uses
# to rsync the built site to Jacobs web hosting (e4e@mywebsite.eng.ucsd.edu:htdocs/).
# Written EARLY so the tenant's fail-closed in-VM vault-agent finds it. See
# docs/onboarding-e4e-website.md.
#
# GENERATE-ONCE. The public half is installed by hand in the e4e account's
# ~/.ssh/authorized_keys on mywebsite: that host is ETS-run, outside this repo, so this
# is the one manual step.
#
# NO ADOPTION PATH. Unlike random_password, tls_private_key does not support `tofu
# import` ("This resource does not support import"), so TOFU_IMPORT can't recover it.
# If this workspace's state ever loses these two resources, deploy-tofu.sh's
# generate-once guard sees a CREATE over an existing OpenBao path and stops the deploy
# (exit 5), like any other secret here. Recovery is a deliberate rotation: rerun with
# TOFU_SECRETS_APPROVE="e4e-website key: state lost, rotating", then install the new
# public key on mywebsite (docs/onboarding-e4e-website.md §2, gate 3). Nothing is lost
# but publishing, until the key is re-installed.
#
#   tenants/e4e-website/generated/mywebsite-ssh   {private_key, public_key}
#       private_key: rendered root-only on the slot (the handoff's deploy/incus/publish.nix);
#                    the GitHub runner never sees it.
#       public_key:  NOT secret. Read it (`bao kv get -field=public_key ...`) to install it
#                    on mywebsite (runbook §2c).
#       Under tenants/+/generated: krg-deploy's writer glob (terraform/openbao/main.tf),
#       so no openbao apply. The tenant AppRole reads it via secret/data/tenants/e4e-website/*.

resource "tls_private_key" "e4e_website_mywebsite" {
  algorithm = "ED25519"
}

resource "vault_kv_secret_v2" "e4e_website_mywebsite_ssh" {
  mount = "secret"
  name  = "tenants/e4e-website/generated/mywebsite-ssh"
  data_json = jsonencode({
    private_key = tls_private_key.e4e_website_mywebsite.private_key_openssh
    # The comment names the key's purpose in mywebsite's authorized_keys.
    public_key = "${trimspace(tls_private_key.e4e_website_mywebsite.public_key_openssh)} e4e-website@krg-nat"
  })
}
