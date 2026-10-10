#!/usr/bin/env bash
# Renders all templates of the repository and checks the result: `nginx -t`
# runs over the nginx configs, `bash -n` and shellcheck over the bootstrap.
#
# This is the only config check available without a server, and it catches
# exactly what would otherwise surface on a real `terraform apply`: a typo, a
# lost brace, a directive in the wrong context.
#
# Usage:  terraform/scripts/check-templates.sh
# Needs nginx in PATH or a running Docker (image nginx:1.24-alpine - the same
# branch as in Ubuntu 24.04 on the server).
#
# `nginx -t` really binds the listen sockets (80 and 443 here), so a local
# (native) nginx needs either root or net.ipv4.ip_unprivileged_port_start <= 80.
# CI sets the sysctl before running this script; on a laptop without it the
# script falls back to Docker (root inside the container) or explains what to do.
# REQUIRE_SHELLCHECK=1 - fail if shellcheck is unavailable (CI runs it this way).
set -euo pipefail

TF_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VARIANTS="http-ip http-domain tls"
NGINX_IMAGE="nginx:1.24-alpine"
SHELLCHECK_IMAGE="koalaman/shellcheck:stable"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

to_mount_path() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
}

# True if this process may bind to ports 80 and 443.
can_bind_low_ports() {
  [ "$(id -u)" -eq 0 ] && return 0
  local start
  start="$(cat /proc/sys/net/ipv4/ip_unprivileged_port_start 2>/dev/null || echo 1024)"
  [ "$start" -le 80 ]
}

# Paths inside the config must match the ones nginx will see:
# for a container it is /work, for a local nginx it is the temp dir itself.
if command -v nginx >/dev/null 2>&1 && can_bind_low_ports; then
  RUNNER=native
  CONF_ROOT="$WORK"
elif docker info >/dev/null 2>&1; then
  RUNNER=docker
  CONF_ROOT=/work
elif command -v nginx >/dev/null 2>&1; then
  echo "nginx -t binds ports 80/443, and this user may not. Either run as root, or:" >&2
  echo "  sudo sysctl -w net.ipv4.ip_unprivileged_port_start=0" >&2
  echo "or start Docker (the check then runs in a container)." >&2
  exit 1
else
  echo "Need nginx in PATH or a running Docker - neither is available." >&2
  exit 1
fi
echo "==> Checking via: $RUNNER"

mkdir -p "$WORK/certs" "$WORK/web" "$WORK/media" "$WORK/out"

# Self-signed certificate: nginx -t reads the certificate files themselves, not
# just the path to them, so the TLS variant cannot be checked without one.
# The double slash in the subject is needed by Git Bash on Windows: otherwise
# MSYS turns "/CN=..." into a path like C:/Program Files/Git/CN=... and openssl
# fails.
if [ -n "${MSYSTEM:-}" ]; then CERT_SUBJ="//CN=brewq.check"; else CERT_SUBJ="/CN=brewq.check"; fi
if ! openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "$CERT_SUBJ" \
  -keyout "$WORK/certs/privkey.pem" -out "$WORK/certs/fullchain.pem" 2>"$WORK/openssl.log"; then
  echo "openssl could not issue the test certificate:" >&2
  cat "$WORK/openssl.log" >&2
  exit 1
fi

echo "==> Rendering templates"
# MSYS_NO_PATHCONV: /work is a path INSIDE the container, and Git Bash must not
# turn it into C:/Program Files/Git/work. The only paths terraform needs in its
# native form are out_dir (and the render state).
terraform -chdir="$(to_mount_path "$TF_ROOT/scripts/render")" init -backend=false -input=false -no-color >/dev/null
MSYS_NO_PATHCONV=1 terraform -chdir="$(to_mount_path "$TF_ROOT/scripts/render")" apply -auto-approve -input=false -no-color \
  -state="$(to_mount_path "$WORK/render.tfstate")" \
  -var "out_dir=$(to_mount_path "$WORK/out")" \
  -var "cert_dir=$CONF_ROOT/certs" \
  -var "web_root=$CONF_ROOT/web" \
  -var "media_dir=$CONF_ROOT/media" >/dev/null

for variant in $VARIANTS; do
  dir="$WORK/$variant"
  mkdir -p "$dir/tmp" "$dir/logs"
  cat > "$dir/nginx.conf" <<CONF
worker_processes 1;
error_log $CONF_ROOT/$variant/logs/error.log;
pid $CONF_ROOT/$variant/logs/nginx.pid;

events { worker_connections 64; }

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;
    access_log    off;

    client_body_temp_path $CONF_ROOT/$variant/tmp;
    proxy_temp_path       $CONF_ROOT/$variant/tmp;
    fastcgi_temp_path     $CONF_ROOT/$variant/tmp;
    uwsgi_temp_path       $CONF_ROOT/$variant/tmp;
    scgi_temp_path        $CONF_ROOT/$variant/tmp;

    include $CONF_ROOT/out/$variant/brewq.conf;
}
CONF

  echo "==> nginx -t: $variant"
  if [ "$RUNNER" = native ]; then
    # -e: nginx opens a compiled-in default error log (/var/log/nginx/...)
    # before it reads the config; a non-root user cannot, so point it at the
    # temp dir.
    nginx -t -p "$WORK/$variant" -c "$WORK/$variant/nginx.conf" -e "$WORK/$variant/logs/error.log"
  else
    MSYS_NO_PATHCONV=1 docker run --rm -v "$(to_mount_path "$WORK")":/work "$NGINX_IMAGE" \
      nginx -t -p "/work/$variant" -c "/work/$variant/nginx.conf"
  fi
done

echo "==> All nginx config variants passed nginx -t"

echo "==> bash -n over the rendered bootstrap"
bash -n "$WORK/out/bootstrap/bootstrap.sh"

echo "==> shellcheck over the rendered bootstrap"
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck --severity=warning "$WORK/out/bootstrap/bootstrap.sh"
elif [ "${REQUIRE_SHELLCHECK:-0}" != 1 ] && docker info >/dev/null 2>&1; then
  MSYS_NO_PATHCONV=1 docker run --rm -v "$(to_mount_path "$WORK/out/bootstrap")":/mnt "$SHELLCHECK_IMAGE" \
    --severity=warning /mnt/bootstrap.sh
elif [ "${REQUIRE_SHELLCHECK:-0}" = 1 ]; then
  echo "shellcheck not found, but REQUIRE_SHELLCHECK=1" >&2
  exit 1
else
  echo "    (neither shellcheck nor Docker - skipped)"
fi

echo "==> Templates are fine"
