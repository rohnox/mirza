#!/usr/bin/env bash
set -euo pipefail

# =========================
# Mirza Pro Installer
# =========================
APP_NAME="mirza_pro"
APP_DIR="/var/www/html/${APP_NAME}"
REPO_URL="https://github.com/mahdiMGF2/mirza_pro.git"
WEB_USER="www-data"
NGINX_CONF="/etc/nginx/sites-available/${APP_NAME}.conf"
PHP_CANDIDATES=("8.3" "8.2" "8.1")

CRON_SCRIPTS=(
  "cronbot/cron.php"
)

# -------- helpers --------
ok(){ echo -e "\e[1;32m[+]\e[0m $*"; }
warn(){ echo -e "\e[1;33m[!]\e[0m $*"; }
die(){ echo -e "\e[1;31m[x]\e[0m $*" >&2; exit 1; }
need_root(){ [ "$(id -u)" -eq 0 ] || die "Run as root (sudo)."; }
has(){ command -v "$1" >/dev/null 2>&1; }

choose_php(){
  add-apt-repository -y ppa:ondrej/php || true
  apt-get update -y
  for v in "${PHP_CANDIDATES[@]}"; do
    if apt-cache policy "php${v}-fpm" | grep -q Candidate; then
      echo "$v"; return 0
    fi
  done
  echo "8.1"
}

phpbin(){
  local v="$1"
  if has "php${v}"; then echo "php${v}"; else echo "php"; fi
}

# -------- steps --------
install_deps(){
  export DEBIAN_FRONTEND=noninteractive
  ok "Updating system & installing dependencies…"
  apt-get update -y
  apt-get upgrade -y
  apt-get install -y software-properties-common curl git unzip ca-certificates lsb-release ufw nginx

  local PV
  PV="$(choose_php)"
  ok "Using PHP ${PV}"
  apt-get install -y "php${PV}-fpm" "php${PV}-cli" "php${PV}-curl" "php${PV}-mbstring" \
                     "php${PV}-xml" "php${PV}-zip" "php${PV}-sqlite3" "php${PV}-gd"

  apt-get install -y certbot python3-certbot-nginx

  if ! has composer; then
    ok "Installing Composer…"
    curl -sS https://getcomposer.org/installer -o /tmp/composer-setup.php
    php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
  fi

  ufw allow OpenSSH || true
  ufw allow 'Nginx Full' || true
}

clone_repo(){
  ok "Cloning ${REPO_URL} → ${APP_DIR}"
  if [ -d "${APP_DIR}/.git" ]; then
    (cd "${APP_DIR}" && git pull --rebase)
  else
    rm -rf "${APP_DIR}"
    git clone --depth=1 "${REPO_URL}" "${APP_DIR}"
  fi
  chown -R "${WEB_USER}:${WEB_USER}" "${APP_DIR}"
}

gather_env(){
  ok "Enter configuration:"
  read -rp "Domain (e.g. bot.example.com): " BOT_DOMAIN
  while [ -z "${BOT_DOMAIN:-}" ]; do read -rp "Domain cannot be empty: " BOT_DOMAIN; done

  read -rp "Telegram Bot Token: " BOT_TOKEN
  while [ -z "${BOT_TOKEN:-}" ]; do read -rp "Bot token cannot be empty: " BOT_TOKEN; done

  read -rp "Admin Telegram ID (numeric): " ADMIN_ID
  while [ -z "${ADMIN_ID:-}" ]; do read -rp "Admin ID cannot be empty: " ADMIN_ID; done

  WEBHOOK_SECRET=$(head -c 12 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 24)

  cat > "${APP_DIR}/.install_env" <<EOF
BOT_DOMAIN=${BOT_DOMAIN}
BOT_TOKEN=${BOT_TOKEN}
ADMIN_ID=${ADMIN_ID}
WEBHOOK_SECRET=${WEBHOOK_SECRET}
EOF
  chown "${WEB_USER}:${WEB_USER}" "${APP_DIR}/.install_env"

  # try to patch config.php if it exists
  if [ -f "${APP_DIR}/config.php" ]; then
    sed -i "s/\(BOT_TOKEN\)\s*=\s*['\"][^'\"]*['\"];/\1='${BOT_TOKEN}';/g" "${APP_DIR}/config.php" || true
    sed -i "s/\(ADMIN_ID\)\s*=\s*['\"][^'\"]*['\"];/\1='${ADMIN_ID}';/g" "${APP_DIR}/config.php" || true
  fi
}

composer_install(){
  if [ -f "${APP_DIR}/composer.json" ]; then
    ok "Running composer install…"
    (cd "${APP_DIR}" && sudo -u "${WEB_USER}" composer install --no-dev --optimize-autoloader)
  else
    ok "composer.json not found — skipping."
  fi
}

write_nginx(){
  source "${APP_DIR}/.install_env"
  local PHPV="$(php -r 'echo PHP_MAJOR_VERSION.\".\".PHP_MINOR_VERSION;')"
  ok "Writing Nginx server block…"
  cat > "${NGINX_CONF}" <<NGX
server {
    listen 80;
    server_name ${BOT_DOMAIN};

    root ${APP_DIR};
    index index.php index.html;

    access_log /var/log/nginx/${APP_NAME}_access.log;
    error_log  /var/log/nginx/${APP_NAME}_error.log;

    location / {
        try_files \$uri /index.php?\$args;
    }

    # Webhook endpoint → webhooks.php
    location /${WEBHOOK_SECRET} {
        include snippets/fastcgi-php.conf;
        fastcgi_param SCRIPT_FILENAME \$document_root/webhooks.php;
        fastcgi_pass unix:/run/php/php${PHPV}-fpm.sock;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php${PHPV}-fpm.sock;
    }

    client_max_body_size 20m;
}
NGX
  ln -sf "${NGINX_CONF}" "/etc/nginx/sites-enabled/${APP_NAME}.conf"
  rm -f /etc/nginx/sites-enabled/default || true
  nginx -t
  systemctl reload nginx
}

issue_ssl(){
  source "${APP_DIR}/.install_env"
  ok "Issuing Let's Encrypt certificate for ${BOT_DOMAIN}…"
  certbot --nginx -d "${BOT_DOMAIN}" --non-interactive --agree-tos -m "admin@${BOT_DOMAIN}" --redirect || \
    warn "Certbot failed — you can retry: certbot --nginx -d ${BOT_DOMAIN} --redirect"
}

permissions(){
  ok "Fixing permissions…"
  chown -R "${WEB_USER}:${WEB_USER}" "${APP_DIR}"
  find "${APP_DIR}" -type d -exec chmod 755 {} \;
  find "${APP_DIR}" -type f -exec chmod 644 {} \;
}

setup_cron(){
  ok "Installing cron jobs (*/5 for cronbot/cron.php if present)…"
  local PHPV="$(php -r 'echo PHP_MAJOR_VERSION.\".\".PHP_MINOR_VERSION;')"
  local PHPBIN="$(phpbin "${PHPV}")"
  local TMP="$(mktemp)"
  crontab -l 2>/dev/null | grep -v "${APP_DIR}" > "${TMP}" || true
  for s in "${CRON_SCRIPTS[@]}"; do
    if [ -f "${APP_DIR}/${s}" ]; then
      echo "*/5 * * * * cd ${APP_DIR} && ${PHPBIN} ${APP_DIR}/${s} >/dev/null 2>&1" >> "${TMP}"
    fi
  done
  crontab "${TMP}"; rm -f "${TMP}"
}

set_webhook(){
  source "${APP_DIR}/.install_env"
  local URL="https://${BOT_DOMAIN}/${WEBHOOK_SECRET}"
  ok "Setting Telegram webhook → ${URL}"
  curl -sS "https://api.telegram.org/bot${BOT_TOKEN}/setWebhook" \
       -d "url=${URL}" \
       -d "drop_pending_updates=true" >/dev/null || warn "Webhook setup failed."
}

summary(){
  source "${APP_DIR}/.install_env"
  cat <<EOF

=========== ${APP_NAME} Installed ===========
Domain:        ${BOT_DOMAIN}
Root:          ${APP_DIR}
Webhook URL:   https://${BOT_DOMAIN}/${WEBHOOK_SECRET}
Nginx conf:    ${NGINX_CONF}
Cron:          */5 → cronbot/cron.php (if present)

Useful:
  sudo systemctl status nginx php*-fpm
  sudo tail -f /var/log/nginx/${APP_NAME}_error.log
  sudo certbot renew --dry-run
============================================
EOF
}

update_app(){
  need_root
  ok "Updating ${APP_NAME}…"
  clone_repo
  composer_install || true
  setup_cron || true
  systemctl reload nginx || true
  summary
}

uninstall_app(){
  need_root
  read -rp "Remove app & Nginx config? (y/N): " YN
  case "${YN:-n}" in
    y|Y)
      rm -f "${NGINX_CONF}" "/etc/nginx/sites-enabled/${APP_NAME}.conf"
      nginx -t && systemctl reload nginx || true
      rm -rf "${APP_DIR}"
      local TMP="$(mktemp)"
      crontab -l 2>/dev/null | grep -v "${APP_DIR}" > "${TMP}" || true
      crontab "${TMP}" || true
      rm -f "${TMP}"
      ok "Uninstalled."
      ;;
    *) ok "Canceled.";;
  esac
}

do_install(){
  need_root
  install_deps
  clone_repo
  gather_env
  composer_install
  write_nginx
  issue_ssl
  permissions
  setup_cron
  set_webhook
  summary
}

menu(){
  echo "==============================="
  echo " ${APP_NAME} Installer"
  echo "==============================="
  echo "1) Install"
  echo "2) Update"
  echo "3) Uninstall"
  echo "0) Exit"
  read -rp "Choose: " CH
  case "${CH:-1}" in
    1) do_install ;;
    2) update_app ;;
    3) uninstall_app ;;
    0) exit 0 ;;
    *) die "Invalid choice";;
  esac
}

menu
