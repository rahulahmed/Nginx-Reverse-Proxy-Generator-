#!/usr/bin/env bash
#
# Rahul Ahmed's Reverse Proxy Wizard
# Production-grade Nginx reverse proxy generator
# Author: Rahul Ahmed

set -u  

NGINX_CONF_DIR="/etc/nginx"
SITES_AVAILABLE="$NGINX_CONF_DIR/sites-available"
SITES_ENABLED="$NGINX_CONF_DIR/sites-enabled"

# ---------- Helpers ----------

red()  { printf "\e[31m%s\e[0m\n" "$*"; }
grn()  { printf "\e[32m%s\e[0m\n" "$*"; }
ylw()  { printf "\e[33m%s\e[0m\n" "$*"; }
blu()  { printf "\e[34m%s\e[0m\n" "$*"; }

pause() { read -rp "Press Enter to continue..."; }

require_root() {
  if [[ "$EUID" -ne 0 ]]; then
    red "❌ This script must be run as root (sudo)."
    exit 1
  fi
}

check_nginx_installed() {
  if ! command -v nginx >/dev/null 2>&1; then
    ylw "⚠️  nginx is not installed."
    read -rp "Install nginx now? (y/n): " ans
    if [[ "$ans" =~ ^[Yy]$ ]]; then
      apt update && apt install -y nginx || {
        red "❌ Failed to install nginx."
        exit 1
      }
      grn "✅ nginx installed."
    else
      red "❌ nginx is required. Aborting."
      exit 1
    fi
  fi
}

ask_non_empty() {
  local prompt var
  prompt="$1"
  while true; do
    read -rp "$prompt" var
    if [[ -n "$var" ]]; then
      echo "$var"
      return
    fi
    ylw "Input cannot be empty, try again."
  done
}

ask_domain() {
  local domain
  while true; do
    domain=$(ask_non_empty "Enter domain (example.com): ")
    # simple validation
    if [[ "$domain" =~ ^[A-Za-z0-9.-]+$ ]]; then
      echo "$domain"
      return
    else
      ylw "Invalid domain format, try again."
    fi
  done
}

ask_port() {
  local port
  while true; do
    read -rp "Enter app port (e.g. 3052): " port
    if [[ "$port" =~ ^[0-9]+$ ]] && (( port > 0 && port < 65536 )); then
      echo "$port"
      return
    else
      ylw "Invalid port. Must be a number between 1–65535."
    fi
  done
}

test_upstream() {
  local host="$1" port="$2"
  ylw "🔎 Testing upstream http://$host:$port ..."
  if command -v curl >/dev/null 2>&1; then
    if curl -s -o /dev/null -w "%{http_code}" "http://$host:$port" | grep -qE '2[0-9][0-9]|3[0-9][0-9]'; then
      grn "✅ Upstream seems reachable."
    else
      ylw "⚠️ Upstream didn't return 2xx/3xx. It may still be booting or misconfigured."
    fi
  else
    ylw "⚠️ curl not found, skipping HTTP test."
  fi
}

ensure_symlink() {
  local src="$1" dst="$2"
  if [[ -L "$dst" || -e "$dst" ]]; then
    # if it's already correct symlink, do nothing
    if [[ -L "$dst" && "$(readlink -f "$dst")" == "$src" ]]; then
      return
    fi
    ylw "ℹ️  $dst already exists. Updating symlink..."
    rm -f "$dst"
  fi
  ln -s "$src" "$dst"
}

run_nginx_test_and_reload() {
  blu "🔁 Testing nginx configuration..."
  if ! nginx -t; then
    red "❌ nginx configuration test failed. Check errors above."
    return 1
  fi
  blu "🔁 Reloading nginx..."
  if ! systemctl reload nginx; then
    red "❌ Failed to reload nginx. Check systemctl status nginx."
    return 1
  fi
  grn "✅ nginx reloaded successfully."
  return 0
}

maybe_install_certbot() {
  if ! command -v certbot >/dev/null 2>&1; then
    ylw "⚠️ certbot not found."
    read -rp "Install certbot + nginx plugin now? (y/n): " ans
    if [[ "$ans" =~ ^[Yy]$ ]]; then
      apt update && apt install -y certbot python3-certbot-nginx || {
        red "❌ Failed to install certbot."
        return 1
      }
      grn "✅ certbot installed."
    else
      ylw "Skipping SSL setup."
      return 1
    fi
  fi
  return 0
}

# ---------- Main ----------

clear
blu "==============================================="
blu "  Rahul Ahmed's Nginx Reverse Proxy Wizard 🚀"
blu "==============================================="
echo

require_root
check_nginx_installed

DOMAIN=$(ask_domain)
read -rp "Use default upstream host 127.0.0.1? (y/n): " use_default_host
if [[ "$use_default_host" =~ ^[Yy]$ ]]; then
  UPSTREAM_HOST="127.0.0.1"
else
  UPSTREAM_HOST=$(ask_non_empty "Enter upstream host (e.g. 127.0.0.1 or 10.0.0.5): ")
fi

UPSTREAM_PORT=$(ask_port)

echo
read -rp "Do you want root (/) to redirect to a sub-path (e.g. /s)? (y/n): " use_root_redirect
ROOT_PATH=""
if [[ "$use_root_redirect" =~ ^[Yy]$ ]]; then
  while true; do
    ROOT_PATH=$(ask_non_empty "Enter sub-path (must start with /, e.g. /s): ")
    if [[ "$ROOT_PATH" =~ ^/ ]]; then
      break
    else
      ylw "Path must start with '/', try again."
    fi
  done
fi

echo
read -rp "Create dedicated access log for this domain? (y/n): " use_custom_logs

ACCESS_LOG="$NGINX_CONF_DIR/logs/${DOMAIN}_access.log"
ERROR_LOG="$NGINX_CONF_DIR/logs/${DOMAIN}_error.log"

# ensure logs dir exists
mkdir -p "$NGINX_CONF_DIR/logs"

CONF="$SITES_AVAILABLE/$DOMAIN"
BACKUP=""

if [[ -f "$CONF" ]]; then
  ylw "ℹ️  Config file already exists: $CONF"
  read -rp "Backup and overwrite (b), overwrite without backup (o), or cancel (c)? [b/o/c]: " choice
  case "$choice" in
    b|B)
      BACKUP="${CONF}.$(date +%Y%m%d_%H%M%S).bak"
      cp "$CONF" "$BACKUP"
      grn "✅ Backup created: $BACKUP"
      ;;
    o|O)
      ylw "Overwriting existing config without backup."
      ;;
    *)
      red "❌ Cancelled by user."
      exit 1
      ;;
  esac
fi

echo
test_upstream "$UPSTREAM_HOST" "$UPSTREAM_PORT"
echo

blu "📝 Generating nginx config for $DOMAIN ..."
{
  echo "server {"
  echo "    listen 80;"
  echo "    server_name $DOMAIN www.$DOMAIN;"

  if [[ -n "$ROOT_PATH" ]]; then
    echo
    echo "    # Redirect root to your app's real entry path"
    echo "    location = / {"
    echo "        return 302 $ROOT_PATH;"
    echo "    }"
  fi

  if [[ "$use_custom_logs" =~ ^[Yy]$ ]]; then
    echo
    echo "    access_log $ACCESS_LOG;"
    echo "    error_log  $ERROR_LOG;"
  fi

  cat <<EOF_INNER

    location / {
        proxy_pass http://$UPSTREAM_HOST:$UPSTREAM_PORT;
        proxy_http_version 1.1;

        # Preserve client information
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # WebSocket / upgrade headers
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

        # Timeouts (tune for production)
        proxy_connect_timeout 60s;
        proxy_send_timeout    60s;
        proxy_read_timeout    60s;

        # Optional: buffer tuning
        proxy_buffering on;
        proxy_buffers 16 16k;
        proxy_buffer_size 16k;
    }

    # Optional: basic health-check endpoint
    location /_nginx_health {
        return 200 'OK - served by nginx for $DOMAIN';
        add_header Content-Type text/plain;
    }
}
EOF_INNER
} > "$CONF"

grn "✅ Nginx config written to: $CONF"

ensure_symlink "$CONF" "$SITES_ENABLED/$DOMAIN"
grn "✅ Symlink ensured: $SITES_ENABLED/$DOMAIN -> $CONF"

if ! run_nginx_test_and_reload; then
  if [[ -n "$BACKUP" ]]; then
    ylw "Restoring backup from $BACKUP ..."
    cp "$BACKUP" "$CONF"
    nginx -t && systemctl reload nginx
    red "Reverted to previous working config."
  fi
  exit 1
fi

ylw "ℹ️  HTTP reverse proxy for $DOMAIN should now be live."
echo "    Try:  http://$DOMAIN  (or http://$DOMAIN$ROOT_PATH)"
echo

# ---------- SSL Section ----------

read -rp "Do you want to enable SSL (HTTPS) for $DOMAIN now? (y/n): " enable_ssl
if [[ "$enable_ssl" =~ ^[Yy]$ ]]; then
  if maybe_install_certbot; then
    blu "🔐 Requesting Let's Encrypt certificate for $DOMAIN ..."
    # certbot will modify nginx config safely
    if certbot --nginx -d "$DOMAIN" -d "www.$DOMAIN"; then
      grn "✅ SSL enabled for $DOMAIN."
      blu "Testing nginx again after SSL changes..."
      if nginx -t && systemctl reload nginx; then
        grn "✅ HTTPS live. Visit: https://$DOMAIN"
      else
        red "⚠️ nginx reload failed after SSL; check config."
      fi
    else
      red "❌ certbot failed to obtain certificate. Check certbot logs."
    fi
  fi
else
  ylw "Skipping SSL for now. You can always run certbot later."
fi

echo
grn "🎉 All done, powered by Rahul Ahmed's Reverse Proxy Wizard! Thanks for using this tools"
