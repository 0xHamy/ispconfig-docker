FROM ubuntu:20.04

# Avoid tzdata prompts during build
ARG DEBIAN_FRONTEND=noninteractive

# -------- Base OS & tools
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      ca-certificates curl wget gnupg apt-transport-https \
      lsb-release locales tzdata \
      supervisor cron rsyslog logrotate \
      openssl git procps iproute2 net-tools dnsutils \
      apache2 libapache2-mod-php php php-cli php-common php-mysql \
      mariadb-server mariadb-client \
      && rm -rf /var/lib/apt/lists/*

# Make /bin/sh use bash (the classic ISPConfig guides require it)
RUN ln -sf /bin/bash /bin/sh

# Supervisor + runtime dirs
RUN mkdir -p /var/log/supervisor /run/mysqld && chown mysql:mysql /run/mysqld

# Sane hostname inside the container (helps the installer)
RUN printf "server1.example.com\n" > /etc/hostname && \
    sed -i '1i127.0.1.1 server1.example.com server1' /etc/hosts

# We’ll run the ISPConfig autoinstaller at *container start* (not at build)
# so services are present and DB is reachable. You can tweak services via this env:
ENV ISP_AUTOINSTALL_FLAGS="--no-mail --no-dns --no-ftp --no-roundcube --no-mailman --no-pma --no-firewall --no-jailkit --no-quota --no-ntp --use-ftp-ports=40110-40210 --unattended-upgrades --i-know-what-i-am-doing"

# Web panel listen port inside container (Apache vhost will be 8080)
ENV PANEL_PORT=8080

# Copy our files
COPY entrypoint.sh /entrypoint.sh
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf
RUN chmod +x /entrypoint.sh

# Enable Apache modules and switch Apache to :8080 globally
RUN a2enmod php7.4 dir rewrite headers && \
    sed -i 's/^[[:space:]]*Listen 80/# Listen 80/' /etc/apache2/ports.conf && \
    grep -q '^Listen 8080' /etc/apache2/ports.conf || echo 'Listen 8080' >> /etc/apache2/ports.conf && \
    printf "ServerName ispconfig.local\n" > /etc/apache2/conf-available/servername.conf && \
    a2enconf servername

EXPOSE 8080

# Start everything via our entrypoint (runs autoinstaller once, then serves panel)
CMD ["/entrypoint.sh"]
