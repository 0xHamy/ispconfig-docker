# Use Ubuntu 20.04 as the base image
FROM ubuntu:20.04

# Set environment variables to avoid interactive prompts
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Etc/UTC
ENV MYSQL_ROOT_PASSWORD=howtoforge
ENV DOMAIN=ispconfig.local
ENV LIST_ADMIN_EMAIL=listadmin@ispconfig.local
ENV MAILMAN_PASSWORD=mailmanpass

# Update package lists and install basic tools
RUN apt-get update && apt-get install -y \
    net-tools \
    curl \
    wget \
    && apt-get clean

# Step 1: Disable AppArmor
RUN service apparmor stop || true \
    && update-rc.d -f apparmor remove || true \
    && apt-get remove -y apparmor apparmor-utils \
    && apt-get clean

# Step 2: Synchronize the System Clock
RUN apt-get install -y ntp \
    && apt-get clean

# Step 3: Install Postfix, Dovecot, MariaDB, rkhunter, and binutils
# Configure postfix non-interactively
RUN echo "postfix postfix/main_mailer_type select Internet Site" | debconf-set-selections \
    && echo "postfix postfix/mailname string $DOMAIN" | debconf-set-selections \
    && service sendmail stop || true \
    && update-rc.d -f sendmail remove || true \
    && apt-get install -y \
        postfix postfix-mysql postfix-doc \
        mariadb-client mariadb-server \
        openssl getmail4 rkhunter binutils \
        dovecot-imapd dovecot-pop3d dovecot-mysql dovecot-sieve \
        sudo patch \
    && apt-get clean

# Configure Postfix master.cf for TLS/SSL and submission ports
RUN sed -i '/^#submission inet n/s/^#//' /etc/postfix/master.cf \
    && sed -i '/^#  -o syslog_name=postfix\/submission/s/^#//' /etc/postfix/master.cf \
    && sed -i '/^#  -o smtpd_tls_security_level=encrypt/s/^#//' /etc/postfix/master.cf \
    && sed -i '/^#  -o smtpd_sasl_auth_enable=yes/s/^#//' /etc/postfix/master.cf \
    && sed -i '/^#  -o smtpd_tls_auth_only=yes/s/^#//' /etc/postfix/master.cf \
    && sed -i '/^#  -o smtpd_client_restrictions=permit_sasl_authenticated,reject/s/^#//' /etc/postfix/master.cf \
    && sed -i '/^#smtps inet n/s/^#//' /etc/postfix/master.cf \
    && sed -i '/^#  -o syslog_name=postfix\/smtps/s/^#//' /etc/postfix/master.cf \
    && sed -i '/^#  -o smtpd_tls_wrappermode=yes/s/^#//' /etc/postfix/master.cf \
    && sed -i '/^#  -o smtpd_sasl_auth_enable=yes/s/^#//' /etc/postfix/master.cf \
    && sed -i '/^#  -o smtpd_client_restrictions=permit_sasl_authenticated,reject/s/^#//' /etc/postfix/master.cf \
    && service postfix restart

# Configure MariaDB to listen on all interfaces
RUN sed -i 's/bind-address\s*=\s*127.0.0.1/#bind-address = 127.0.0.1/' /etc/mysql/mariadb.conf.d/50-server.cnf

# Initialize MariaDB and set root password using socket auth (no skip-grant-tables)
RUN mkdir -p /run/mysqld && chown -R mysql:mysql /run/mysqld \
 && mysqld_safe --datadir=/var/lib/mysql --socket=/run/mysqld/mysqld.sock & \
    for i in $(seq 1 30); do mysqladmin --protocol=socket -uroot ping 2>/dev/null && break; sleep 1; done \
 && mysql --protocol=socket -uroot -e "\
      UPDATE mysql.user \
        SET plugin='mysql_native_password' \
        WHERE user='root' AND host='localhost'; \
      SET PASSWORD FOR 'root'@'localhost' = PASSWORD('${MYSQL_ROOT_PASSWORD}'); \
      DELETE FROM mysql.user WHERE user=''; \
      DELETE FROM mysql.user WHERE user='root' AND host NOT IN ('localhost','127.0.0.1','::1'); \
      FLUSH PRIVILEGES;" \
 && killall mysqld || true && sleep 3

# Update MariaDB debian.cnf with root password
RUN sed -i "s/password\s*=.*/password = $MYSQL_ROOT_PASSWORD/" /etc/mysql/debian.cnf

# Configure MySQL limits
RUN echo "mysql soft nofile 65535" >> /etc/security/limits.conf \
    && echo "mysql hard nofile 65535" >> /etc/security/limits.conf \
    && mkdir -p /etc/systemd/system/mysql.service.d/ \
    && echo "[Service]\nLimitNOFILE=infinity" > /etc/systemd/system/mysql.service.d/limits.conf \
    && systemctl daemon-reload \
    && service mariadb restart

# Verify MariaDB networking
RUN netstat -tap | grep mysql || true

# Step 4: Install Amavisd-new, SpamAssassin, and ClamAV
RUN apt-get install -y \
    amavisd-new spamassassin clamav clamav-daemon \
    unzip bzip2 arj nomarch lzop cabextract \
    apt-listchanges libnet-ldap-perl libauthen-sasl-perl \
    clamav-docs daemon libio-string-perl libio-socket-ssl-perl \
    libnet-ident-perl zip libnet-dns-perl postgrey \
    && apt-get clean \
    && service spamassassin stop \
    && update-rc.d -f spamassassin remove \
    && freshclam || true \
    && service clamav-daemon start

# Step 5: Install Apache, PHP, phpMyAdmin, FCGI, SuExec, Pear
RUN echo "phpmyadmin phpmyadmin/dbconfig-install boolean true" | debconf-set-selections \
    && echo "phpmyadmin phpmyadmin/reconfigure-webserver multiselect apache2" | debconf-set-selections \
    && echo "phpmyadmin phpmyadmin/mysql/app-pass password ''" | debconf-set-selections \
    && apt-get install -y \
    apache2 apache2-doc apache2-utils \
    libapache2-mod-php php7.4 php7.4-common php7.4-gd php7.4-mysql \
    php7.4-imap phpmyadmin php7.4-cli php7.4-cgi \
    libapache2-mod-fcgid apache2-suexec-pristine php-pear libruby \
    libapache2-mod-python php7.4-curl php7.4-intl php7.4-pspell \
    php7.4-sqlite3 php7.4-tidy php7.4-xmlrpc php7.4-xsl \
    memcached php-memcache php-imagick php7.4-zip php7.4-mbstring \
    php-soap php7.4-soap php7.4-opcache php-apcu php7.4-fpm \
    libapache2-reload-perl \
    && apt-get clean

# Enable Apache modules
RUN a2enmod suexec rewrite ssl actions include cgi alias proxy_fcgi dav_fs dav auth_digest headers

# Configure HTTP_PROXY protection
RUN echo "<IfModule mod_headers.c>\n    RequestHeader unset Proxy early\n</IfModule>" > /etc/apache2/conf-available/httpoxy.conf \
    && a2enconf httpoxy \
    && service apache2 restart

# Comment out Ruby mime type
RUN sed -i 's/application\/x-ruby/#application\/x-ruby/' /etc/mime.types \
    && service apache2 restart

# Step 6: Install Let's Encrypt
RUN apt-get install -y certbot \
    && apt-get clean

# Step 7: Install Mailman
RUN echo "mailman mailman/default_language multiselect en" | debconf-set-selections \
    && echo "mailman mailman/site_languages multiselect en" | debconf-set-selections \
    && apt-get install -y mailman \
    && apt-get clean \
    && echo "y" | newlist mailman -e "$LIST_ADMIN_EMAIL" -p "$MAILMAN_PASSWORD" \
    && echo "mailman: \"|/var/lib/mailman/mail/mailman post mailman\"" >> /etc/aliases \
    && echo "mailman-admin: \"|/var/lib/mailman/mail/mailman admin mailman\"" >> /etc/aliases \
    && echo "mailman-bounces: \"|/var/lib/mailman/mail/mailman bounces mailman\"" >> /etc/aliases \
    && echo "mailman-confirm: \"|/var/lib/mailman/mail/mailman confirm mailman\"" >> /etc/aliases \
    && echo "mailman-join: \"|/var/lib/mailman/mail/mailman join mailman\"" >> /etc/aliases \
    && echo "mailman-leave: \"|/var/lib/mailman/mail/mailman leave mailman\"" >> /etc/aliases \
    && echo "mailman-owner: \"|/var/lib/mailman/mail/mailman owner mailman\"" >> /etc/aliases \
    && echo "mailman-request: \"|/var/lib/mailman/mail/mailman request mailman\"" >> /etc/aliases \
    && echo "mailman-subscribe: \"|/var/lib/mailman/mail/mailman subscribe mailman\"" >> /etc/aliases \
    && echo "mailman-unsubscribe: \"|/var/lib/mailman/mail/mailman unsubscribe mailman\"" >> /etc/aliases \
    && newaliases \
    && service postfix restart \
    && ln -s /etc/mailman/apache.conf /etc/apache2/conf-available/mailman.conf \
    && a2enconf mailman \
    && service apache2 restart \
    && service mailman start

# Step 8: Install PureFTPd and Quota
RUN apt-get install -y pure-ftpd-common pure-ftpd-mysql quota quotatool \
    && apt-get clean \
    && sed -i 's/STANDALONE_OR_INETD=.*/STANDALONE_OR_INETD=standalone/' /etc/default/pure-ftpd-common \
    && sed -i 's/VIRTUALCHROOT=.*/VIRTUALCHROOT=true/' /etc/default/pure-ftpd-common \
    && echo 1 > /etc/pure-ftpd/conf/TLS \
    && mkdir -p /etc/ssl/private/ \
    && openssl req -x509 -nodes -days 7300 -newkey rsa:2048 \
        -keyout /etc/ssl/private/pure-ftpd.pem \
        -out /etc/ssl/private/pure-ftpd.pem \
        -subj "/C=DE/ST=State/L=City/O=Organization/OU=IT/CN=$DOMAIN/emailAddress=$LIST_ADMIN_EMAIL" \
    && chmod 600 /etc/ssl/private/pure-ftpd.pem \
    && service pure-ftpd-mysql restart \
    && sed -i 's/errors=remount-ro/errors=remount-ro,usrjquota=quota.user,grpjquota=quota.group,jqfmt=vfsv0/' /etc/fstab \
    && mount -o remount / || true \
    && quotacheck -avugm || true \
    && quotaon -avug || true

# Step 9: Install BIND DNS Server
RUN apt-get install -y bind9 dnsutils haveged \
    && apt-get clean \
    && systemctl enable haveged \
    && systemctl start haveged

# Step 10: Install Vlogger, Webalizer, AWStats, and GoAccess
RUN echo "deb https://deb.goaccess.io/ $(lsb_release -cs) main" >> /etc/apt/sources.list.d/goaccess.list \
    && wget -O - https://deb.goaccess.io/gnugpg.key | apt-key --keyring /etc/apt/trusted.gpg.d/goaccess.gpg add - \
    && apt-get update \
    && apt-get install -y vlogger webalizer awstats geoip-database libclass-dbi-mysql-perl goaccess \
    && apt-get clean \
    && sed -i 's/^/#/' /etc/cron.d/awstats

# Step 11: Install fail2ban and UFW
RUN apt-get install -y fail2ban ufw \
    && apt-get clean \
    && echo "[pure-ftpd]\nenabled = true\nport = ftp\nfilter = pure-ftpd\nlogpath = /var/log/syslog\nmaxretry = 3\n\n[dovecot]\nenabled = true\nfilter = dovecot\naction = iptables-multiport[name=dovecot-pop3imap, port=\"pop3,pop3s,imap,imaps\", protocol=tcp]\nlogpath = /var/log/mail.log\nmaxretry = 5\n\n[postfix]\nenabled = true\nport = smtp\nfilter = postfix\nlogpath = /var/log/mail.log\nmaxretry = 3" > /etc/fail2ban/jail.local \
    && service fail2ban restart

# Step 12: Install Roundcube Webmail
RUN echo "roundcube roundcube/dbconfig-install boolean true" | debconf-set-selections \
    && echo "roundcube roundcube/mysql/app-pass password ''" | debconf-set-selections \
    && apt-get install -y \
        roundcube roundcube-core roundcube-mysql roundcube-plugins roundcube-plugins-extra \
        javascript-common libjs-jquery-mousewheel php-net-sieve tinymce \
    && apt-get clean \
    && sed -i 's/#Alias \/roundcube/Alias \/roundcube/' /etc/apache2/conf-enabled/roundcube.conf \
    && echo "Alias /webmail /var/lib/roundcube" >> /etc/apache2/conf-enabled/roundcube.conf \
    && sed -i '/<Directory \/var\/lib\/roundcube>/a AddType application/x-httpd-php .php' /etc/apache2/conf-enabled/roundcube.conf \
    && sed -i "s/\$config\['default_host'\] = .*/\$config['default_host'] = 'localhost';/" /etc/roundcube/config.inc.php \
    && sed -i "s/\$config\['smtp_server'\] = .*/\$config['smtp_server'] = 'localhost';/" /etc/roundcube/config.inc.php \
    && sed -i "s/\$config\['smtp_port'\] = .*/\$config['smtp_port'] = 25;/" /etc/roundcube/config.inc.php \
    && service apache2 restart

# Keep container running
CMD ["tail", "-f", "/dev/null"]