#!/usr/bin/env bash
set -euo pipefail

echo "[ENTRYPOINT] Preparing runtime..."

# Ensure runtime sockets
mkdir -p /run/mysqld
chown mysql:mysql /run/mysqld

# Initialize MariaDB if needed
if [ ! -d /var/lib/mysql/mysql ]; then
  echo "[ENTRYPOINT] Initializing MariaDB data dir..."
  mariadb-install-db --user=mysql --datadir=/var/lib/mysql
fi

# Start Supervisor (apache, mariadb, cron, rsyslog) in background
/usr/bin/supervisord -c /etc/supervisor/supervisord.conf &

# Give services a moment
sleep 2 || true

# Run ISPConfig auto-installer ONCE (idempotent by presence of interface index.php)
if [ ! -f /usr/local/ispconfig/interface/web/index.php ]; then
  echo "[ENTRYPOINT] Running ISPConfig autoinstaller (this can take a while)..."
  export DEBIAN_FRONTEND=noninteractive
  # Official installer: https://get.ispconfig.org (HowtoForge/ISPConfig)
  bash -lc 'wget -O - https://get.ispconfig.org | sh -s -- '"$ISP_AUTOINSTALL_FLAGS" || true

  # Remove conflicting vhosts (installer may add its own 000-ispconfig with a Listen line)
  rm -f /etc/apache2/sites-enabled/000-ispconfig* /etc/apache2/sites-enabled/999-acme || true
  sed -i 's/^[[:space:]]*Listen[[:space:]]*8080/# removed duplicate Listen 8080/' /etc/apache2/sites-available/000-ispconfig* 2>/dev/null || true

  # Minimal clean panel vhost (HTTP on :8080, no SSL)
  cat >/etc/apache2/sites-available/000-panel.conf <<EOF
<VirtualHost *:${PANEL_PORT}>
    ServerAdmin webmaster@localhost
    DocumentRoot /usr/local/ispconfig/interface/web
    DirectoryIndex index.php index.html

    <Directory /usr/local/ispconfig/interface/web>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
        php_admin_value session.save_path "/usr/local/ispconfig/interface/temp"
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/ispconfig_error.log
    CustomLog \${APACHE_LOG_DIR}/ispconfig_access.log combined
</VirtualHost>
EOF

  mkdir -p /usr/local/ispconfig/interface/temp
  chown -R ispconfig:www-data /usr/local/ispconfig/interface/temp
  chmod 770 /usr/local/ispconfig/interface/temp

  a2dissite 000-default.conf default-ssl.conf 2>/dev/null || true
  a2dismod ssl 2>/dev/null || true
  a2ensite 000-panel.conf || true
  apache2ctl -k graceful || true
fi

# Ensure Apache can read interface (prevents 403)
if [ -d /usr/local/ispconfig ]; then
  chown -R ispconfig:www-data /usr/local/ispconfig || true
  find /usr/local/ispconfig -type d -exec chmod 755 {} \; || true
  find /usr/local/ispconfig -type f -exec chmod 644 {} \; || true
fi

echo "[ENTRYPOINT] Ready. Panel should be at http://127.0.0.1:8800 (host) -> :8080 (container)."
# Keep the foreground process from supervisor
wait -n

