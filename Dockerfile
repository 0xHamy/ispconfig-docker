FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
WORKDIR /root

# Install ISPConfig dependencies
RUN apt-get update && apt-get install -y \
    apache2 libapache2-mod-php \
    mariadb-server mariadb-client \
    php php-cli php-common php-mysql php-curl php-mbstring php-gd php-soap php-intl php-xml php-zip php-imap php-fpm \
    postfix postfix-mysql \
    dovecot-core dovecot-imapd dovecot-pop3d dovecot-mysql \
    bind9 dnsutils \
    pure-ftpd-mysql \
    rspamd redis-server \
    clamav clamav-daemon spamassassin \
    certbot \
    supervisor cron rsyslog wget unzip tar git \
    libunwind-dev libpcre2-8-0 \
    && rm -rf /var/lib/apt/lists/*

# MariaDB: create socket dir and initialize data dir (no systemd in container)
RUN mkdir -p /run/mysqld && chown mysql:mysql /run/mysqld
RUN mariadb-install-db --user=mysql --datadir=/var/lib/mysql

# (Optional) seed ClamAV db so clamd can start if you ever enable it
RUN freshclam || true

# Copy ISPConfig tarball from build context
COPY ISPConfig-3.3.0p2.tar.gz /root/

# Extract ISPConfig
RUN tar xvf ISPConfig-3.3.0p2.tar.gz -C /root/ && rm ISPConfig-3.3.0p2.tar.gz

# Autoinstall answers
COPY autoinstall.ini /root/ispconfig3_install/install/autoinstall.ini

# Supervisor config
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf

# Run ISPConfig installer (ignore non-zero to keep build going if services aren't up yet)
RUN php /root/ispconfig3_install/install/install.php --autoinstall=/root/ispconfig3_install/install/autoinstall.ini || true

# Ensure Apache listens on 8080 and has an ISPConfig vhost
RUN echo "Listen 8080" >> /etc/apache2/ports.conf && \
    cat <<'EOF' > /etc/apache2/sites-available/ispconfig.vhost.conf
<VirtualHost *:8080>
    ServerAdmin webmaster@localhost
    DocumentRoot /usr/local/ispconfig/interface/web
    <Directory /usr/local/ispconfig/interface/web>
        AllowOverride All
        Require all granted
    </Directory>
    ErrorLog ${APACHE_LOG_DIR}/ispconfig_error.log
    CustomLog ${APACHE_LOG_DIR}/ispconfig_access.log combined
</VirtualHost>
EOF

# Enable the site (a2ensite expects the .conf name, not a path)
RUN a2ensite ispconfig.vhost.conf

EXPOSE 8080

CMD ["/usr/bin/supervisord", "-n"]
