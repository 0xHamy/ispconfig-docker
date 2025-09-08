FROM ubuntu:20.04

ARG DEBIAN_FRONTEND=noninteractive

# Base OS & core packages
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      ca-certificates curl wget gnupg apt-transport-https \
      lsb-release locales tzdata \
      supervisor cron rsyslog logrotate \
      openssl git procps iproute2 net-tools dnsutils \
      apache2 apache2-utils apache2-doc \
      libapache2-mod-php libapache2-mod-php7.4 \
      php php-cli php-common php-mysql \
      mariadb-server mariadb-client \
      && rm -rf /var/lib/apt/lists/*

# /bin/sh -> bash (classic ISPConfig guides require it)
RUN ln -sf /bin/bash /bin/sh

# Supervisor & MariaDB runtime dir
RUN mkdir -p /var/log/supervisor /run/mysqld && chown mysql:mysql /run/mysqld

# We’ll run the ISPConfig autoinstaller at container start (not during build).
# Toggle services here (see docker-compose.yml too).
ENV ISP_AUTOINSTALL_FLAGS="--no-mail --no-dns --no-ftp --no-roundcube --no-mailman --no-pma --no-firewall --no-jailkit --no-quota --no-ntp --use-ftp-ports=40110-40210 --unattended-upgrades --i-know-what-i-am-doing"

# Apache panel port inside container
ENV PANEL_PORT=8080

# Files
COPY entrypoint.sh /entrypoint.sh
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf
RUN chmod +x /entrypoint.sh

# Apache modules and listener on :8080 (no duplicate Listen in sites)
RUN a2enmod php7.4 dir rewrite headers && \
    sed -i 's/^[[:space:]]*Listen 80/# Listen 80/' /etc/apache2/ports.conf && \
    grep -q '^Listen 8080' /etc/apache2/ports.conf || echo 'Listen 8080' >> /etc/apache2/ports.conf && \
    printf "ServerName ispconfig.local\n" > /etc/apache2/conf-available/servername.conf && \
    a2enconf servername

EXPOSE 8080

CMD ["/entrypoint.sh"]
