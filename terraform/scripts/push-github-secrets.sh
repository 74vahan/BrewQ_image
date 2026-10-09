#!/usr/bin/env bash
# Copies the results of `terraform apply` into secrets and variables of the
# BrewQ_infra GitHub repository - the one that has the deploy.
#
# Why by hand rather than by a pipeline: the state of this repository holds the
# deploy private key and all passwords. A pipeline must not be given such a
# state, so there is neither a deploy workflow nor cloud access from CI here.
#
# The MySQL passwords and the barista password are not copied to GitHub: they
# are needed only on the server (/srv/brewq/.env), and the operator hands the
# password to the barista.
#
# Usage (from the repository root, after apply):
#   terraform/scripts/push-github-secrets.sh
#   REPO=owner/BrewQ_infra terraform/scripts/push-github-secrets.sh
#
# Needs gh (GitHub CLI) with permission to write secrets: gh auth login
set -euo pipefail

REPO="${REPO:-74vahan/BrewQ_infra}"
TF_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

command -v gh >/dev/null 2>&1 || { echo "gh (GitHub CLI) not found: https://cli.github.com" >&2; exit 1; }
command -v ssh-keyscan >/dev/null 2>&1 || { echo "ssh-keyscan not found (OpenSSH package)" >&2; exit 1; }

tf() { terraform -chdir="$TF_ROOT" output -raw "$1"; }

SERVER_HOST="$(tf external_ip)"
SERVER_USER="$(tf ssh_user)"
APP_ROOT="$(tf app_root)"
PUBLIC_BASE_URL="$(tf public_url)"

echo "==> Repository: $REPO"
echo "==> Server:        $SERVER_USER@$SERVER_HOST ($APP_ROOT)"
echo "==> Public URL:    $PUBLIC_BASE_URL"

echo "==> Secrets"
printf '%s' "$SERVER_HOST" | gh secret set SERVER_HOST --repo "$REPO"
printf '%s' "$SERVER_USER" | gh secret set SERVER_USER --repo "$REPO"
tf deploy_private_key_pem | gh secret set SSH_PRIVATE_KEY --repo "$REPO"

# known_hosts closes the MITM window on the pipeline's first connection.
# The key is taken from the server right now - this is trust on first use;
# the fingerprint can be verified via `gcloud compute ssh`.
echo "==> Scanning host key ($SERVER_HOST)"
KNOWN_HOSTS="$(ssh-keyscan -T 15 -H "$SERVER_HOST" 2>/dev/null)"
[ -n "$KNOWN_HOSTS" ] || { echo "ssh-keyscan returned nothing - is the server up yet?" >&2; exit 1; }
printf '%s\n' "$KNOWN_HOSTS" | gh secret set SSH_KNOWN_HOSTS --repo "$REPO"

echo "==> Variables"
printf '%s' "$APP_ROOT" | gh variable set APP_ROOT --repo "$REPO"
printf '%s' "$PUBLIC_BASE_URL" | gh variable set PUBLIC_BASE_URL --repo "$REPO"

echo "==> Done. Verify with: gh secret list --repo $REPO && gh variable list --repo $REPO"
