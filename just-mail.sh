#!/bin/bash
# =====================================================
# AIO Mail Server Installer for Debian 12
# Postfix + Dovecot + SQLite + Let's Encrypt + Roundcube
# =====================================================

set -e

# Warna
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

clear
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}   AIO Mail Server Installer${NC}"
echo -e "${GREEN}   For Debian 12${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# =====================================================
# USER INPUT - No hardcoded values!
# =====================================================

# Get domain
echo -e "${BLUE}📧 Domain Configuration${NC}"
read -p "Enter your domain (example: neomovie.qzz.io): " DOMAIN
while [[ -z "$DOMAIN" ]]; do
    echo -e "${RED}Domain cannot be empty!${NC}"
    read -p "Enter your domain: " DOMAIN
done

# Set hostname
HOSTNAME="mail.${DOMAIN}"

# Get VPS IP automatically
VPS_IP=$(curl -s ifconfig.me)
echo -e "${GREEN}✓ Detected VPS IP: ${VPS_IP}${NC}"
read -p "Is this correct? (y/n): " confirm_ip
if [[ "$confirm_ip" != "y" ]]; then
    read -p "Enter your VPS IP manually: " VPS_IP
fi

# Generate random admin password
ADMIN_PASS=$(openssl rand -base64 16 | tr -d "=+/" | cut -c1-16)
ADMIN_EMAIL="admin@${DOMAIN}"

echo ""
echo -e "${GREEN}✓ Admin email will be: ${ADMIN_EMAIL}${NC}"
echo -e "${YELLOW}✓ Auto-generated password: ${ADMIN_PASS}${NC}"
echo -e "${RED}⚠️  SAVE THIS PASSWORD: ${ADMIN_PASS}${NC}"
echo ""
read -p "Do you want to change the admin password? (y/n): " change_pass
if [[ "$change_pass" == "y" ]]; then
    read -s -p "Enter new admin password: " ADMIN_PASS
    echo ""
    read -s -p "Confirm password: " admin_pass_confirm
    echo ""
    if [[ "$ADMIN_PASS" != "$admin_pass_confirm" ]]; then
        echo -e "${RED}Passwords do not match! Using generated password.${NC}"
        ADMIN_PASS=$(openssl rand -base64 16 | tr -d "=+/" | cut -c1-16)
        echo -e "${YELLOW}New generated password: ${ADMIN_PASS}${NC}"
    fi
fi

# Get admin email for Let's Encrypt
echo ""
read -p "Email for Let's Encrypt notifications (default: ${ADMIN_EMAIL}): " LE_EMAIL
LE_EMAIL=${LE_EMAIL:-$ADMIN_EMAIL}

# Confirm all settings
echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Configuration Summary:${NC}"
echo -e "${BLUE}========================================${NC}"
echo -e "Domain: ${GREEN}${DOMAIN}${NC}"
echo -e "Hostname: ${GREEN}${HOSTNAME}${NC}"
echo -e "VPS IP: ${GREEN}${VPS_IP}${NC}"
echo -e "Admin Email: ${GREEN}${ADMIN_EMAIL}${NC}"
echo -e "Admin Password: ${YELLOW}${ADMIN_PASS}${NC}"
echo -e "Let's Encrypt Email: ${GREEN}${LE_EMAIL}${NC}"
echo ""
read -p "Proceed with installation? (y/n): " confirm
if [[ "$confirm" != "y" ]]; then
    echo -e "${RED}Installation cancelled.${NC}"
    exit 1
fi

# =====================================================
# PATHS
# =====================================================
DB_PATH="/etc/mail/sqlite/mailserver.db"

# =====================================================
# 1. Set Hostname
# =====================================================
echo -e "\n${YELLOW}[1] Setting hostname...${NC}"
hostnamectl set-hostname ${HOSTNAME}
cat > /etc/hosts <<EOF
127.0.0.1 localhost
${VPS_IP} ${HOSTNAME} mail
::1 localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF

# =====================================================
# 2. Create vmail User (FIRST!)
# =====================================================
echo -e "\n${YELLOW}[2] Creating vmail user...${NC}"
groupadd -r vmail -g 5000 2>/dev/null || true
useradd -r -g vmail -u 5000 -d /var/mail -s /usr/sbin/nologin vmail 2>/dev/null || true
mkdir -p /var/mail/vhosts
chown -R vmail:vmail /var/mail

# =====================================================
# 3. Install Packages
# =====================================================
echo -e "\n${YELLOW}[3] Installing packages...${NC}"
apt update
apt install -y postfix postfix-sqlite dovecot-core dovecot-imapd \
    dovecot-pop3d dovecot-lmtpd dovecot-sqlite sqlite3 certbot \
    nginx php-fpm php-sqlite3 php-mbstring php-xml php-curl \
    roundcube roundcube-core roundcube-sqlite3 mailutils \
    opendkim opendkim-tools ufw wget curl

# =====================================================
# 4. Setup SQLite Database
# =====================================================
echo -e "\n${YELLOW}[4] Setting up SQLite database...${NC}"
mkdir -p /etc/mail/sqlite

sqlite3 ${DB_PATH} <<EOF
CREATE TABLE IF NOT EXISTS virtual_domains (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL UNIQUE
);

CREATE TABLE IF NOT EXISTS virtual_users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    domain_id INTEGER NOT NULL,
    email TEXT NOT NULL UNIQUE,
    password TEXT NOT NULL,
    FOREIGN KEY (domain_id) REFERENCES virtual_domains(id)
);

CREATE TABLE IF NOT EXISTS virtual_aliases (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    domain_id INTEGER NOT NULL,
    source TEXT NOT NULL,
    destination TEXT NOT NULL,
    FOREIGN KEY (domain_id) REFERENCES virtual_domains(id)
);
EOF

# Insert domain
DOMAIN_EXISTS=$(sqlite3 ${DB_PATH} "SELECT COUNT(*) FROM virtual_domains WHERE name='${DOMAIN}';")
if [ "$DOMAIN_EXISTS" -eq 0 ]; then
    sqlite3 ${DB_PATH} "INSERT INTO virtual_domains (name) VALUES ('${DOMAIN}');"
    echo "  ✓ Domain ${DOMAIN} added"
fi

# Insert admin user
HASH=$(doveadm pw -s SHA512-CRYPT -p "${ADMIN_PASS}")
DOMAIN_ID=$(sqlite3 ${DB_PATH} "SELECT id FROM virtual_domains WHERE name='${DOMAIN}';")
sqlite3 ${DB_PATH} "INSERT INTO virtual_users (domain_id, email, password) VALUES (${DOMAIN_ID}, '${ADMIN_EMAIL}', '${HASH}');"
echo "  ✓ Admin user created"

chmod 640 ${DB_PATH}
chown root:postfix ${DB_PATH}

# Create mail directory
mkdir -p /var/mail/vhosts/${DOMAIN}/admin/{cur,new,tmp}
chown -R vmail:vmail /var/mail/vhosts/${DOMAIN}

# =====================================================
# 5. Configure Postfix
# =====================================================
echo -e "\n${YELLOW}[5] Configuring Postfix...${NC}"

postconf -e "myhostname = ${HOSTNAME}"
postconf -e "mydomain = ${DOMAIN}"
postconf -e "myorigin = \$mydomain"
postconf -e "inet_interfaces = all"
postconf -e "inet_protocols = ipv4"
postconf -e "mydestination = localhost"
postconf -e "mynetworks = 127.0.0.0/8"
postconf -e "virtual_transport = lmtp:unix:private/dovecot-lmtp"
postconf -e "virtual_mailbox_domains = sqlite:/etc/postfix/sqlite_virtual_domains.cf"
postconf -e "virtual_mailbox_maps = sqlite:/etc/postfix/sqlite_virtual_mailboxes.cf"
postconf -e "virtual_alias_maps = sqlite:/etc/postfix/sqlite_virtual_aliases.cf"
postconf -e "smtpd_relay_restrictions = permit_mynetworks, permit_sasl_authenticated, reject_unauth_destination"
postconf -e "smtpd_recipient_restrictions = permit_sasl_authenticated, permit_mynetworks, reject_unauth_destination"
postconf -e "smtpd_sasl_type = dovecot"
postconf -e "smtpd_sasl_path = private/auth"
postconf -e "smtpd_sasl_auth_enable = yes"
postconf -e "smtpd_sasl_security_options = noanonymous"
postconf -e "smtpd_tls_security_level = may"
postconf -e "smtpd_tls_auth_only = yes"

# SQLite config files
cat > /etc/postfix/sqlite_virtual_domains.cf <<EOF
dbpath = ${DB_PATH}
query = SELECT name FROM virtual_domains WHERE name='%s'
EOF

cat > /etc/postfix/sqlite_virtual_mailboxes.cf <<EOF
dbpath = ${DB_PATH}
query = SELECT email FROM virtual_users WHERE email='%s'
EOF

cat > /etc/postfix/sqlite_virtual_aliases.cf <<EOF
dbpath = ${DB_PATH}
query = SELECT destination FROM virtual_aliases WHERE source='%s'
EOF

chmod 644 /etc/postfix/sqlite_*.cf
chown root:root /etc/postfix/sqlite_*.cf

# =====================================================
# 6. Configure Postfix Master (Submission Ports)
# =====================================================
echo -e "\n${YELLOW}[6] Configuring Postfix master...${NC}"
cp /etc/postfix/master.cf /etc/postfix/master.cf.backup

cat >> /etc/postfix/master.cf <<'EOF'

# Submission port (587) for mail clients
submission inet n       -       y       -       -       smtpd
  -o syslog_name=postfix/submission
  -o smtpd_tls_security_level=encrypt
  -o smtpd_sasl_auth_enable=yes
  -o smtpd_sasl_type=dovecot
  -o smtpd_sasl_path=private/auth
  -o smtpd_sasl_security_options=noanonymous
  -o smtpd_client_restrictions=permit_sasl_authenticated,reject
  -o smtpd_relay_restrictions=permit_sasl_authenticated,reject
  -o milter_macro_daemon_name=ORIGINATING

# SMTPS port (465) for legacy SSL
smtps inet n       -       y       -       -       smtpd
  -o syslog_name=postfix/smtps
  -o smtpd_tls_wrappermode=yes
  -o smtpd_sasl_auth_enable=yes
  -o smtpd_sasl_type=dovecot
  -o smtpd_sasl_path=private/auth
  -o smtpd_client_restrictions=permit_sasl_authenticated,reject
  -o smtpd_relay_restrictions=permit_sasl_authenticated,reject
EOF

# =====================================================
# 7. Configure Dovecot
# =====================================================
echo -e "\n${YELLOW}[7] Configuring Dovecot...${NC}"

cat > /etc/dovecot/conf.d/10-auth.conf <<'EOF'
disable_plaintext_auth = no
auth_mechanisms = plain login scram-sha-256 scram-sha-1
!include auth-sql.conf.ext
EOF

cat > /etc/dovecot/dovecot-sqlite.conf.ext <<EOF
driver = sqlite
connect = ${DB_PATH}
default_pass_scheme = SHA512-CRYPT
password_query = SELECT email as user, password FROM virtual_users WHERE email='%u'
EOF

chmod 640 /etc/dovecot/dovecot-sqlite.conf.ext
chown root:dovecot /etc/dovecot/dovecot-sqlite.conf.ext

cat > /etc/dovecot/conf.d/auth-sql.conf.ext <<'EOF'
passdb {
  driver = sql
  args = /etc/dovecot/dovecot-sqlite.conf.ext
}
userdb {
  driver = static
  args = uid=vmail gid=vmail home=/var/mail/vhosts/%d/%n
}
EOF

cat > /etc/dovecot/conf.d/10-mail.conf <<'EOF'
mail_location = maildir:/var/mail/vhosts/%d/%n
mail_privileged_group = mail

namespace inbox {
  inbox = yes
  separator = /

  mailbox Drafts {
    auto = subscribe
    special_use = \Drafts
  }
  mailbox Junk {
    auto = subscribe
    special_use = \Junk
  }
  mailbox Trash {
    auto = subscribe
    special_use = \Trash
  }
  mailbox Sent {
    auto = subscribe
    special_use = \Sent
  }
}
EOF

cat > /etc/dovecot/conf.d/15-lmtp.conf <<'EOF'
service lmtp {
  unix_listener /var/spool/postfix/private/dovecot-lmtp {
    mode = 0600
    user = postfix
    group = postfix
  }
}
protocol lmtp {
  postmaster_address = postmaster@${DOMAIN}
}
EOF

cat > /etc/dovecot/conf.d/10-master.conf <<'EOF'
service auth {
  unix_listener /var/spool/postfix/private/auth {
    mode = 0660
    user = postfix
    group = postfix
  }
  unix_listener auth-userdb {
    mode = 0600
    user = vmail
  }
  user = dovecot
}
EOF

# =====================================================
# 8. SSL Setup (Temp self-signed, then Let's Encrypt)
# =====================================================
echo -e "\n${YELLOW}[8] Setting up SSL...${NC}"
mkdir -p /etc/dovecot/ssl
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout /etc/dovecot/ssl/dovecot.key \
    -out /etc/dovecot/ssl/dovecot.crt \
    -subj "/CN=${HOSTNAME}" 2>/dev/null

cat > /etc/dovecot/conf.d/10-ssl.conf <<EOF
ssl = required
ssl_cert = </etc/dovecot/ssl/dovecot.crt
ssl_key = </etc/dovecot/ssl/dovecot.key
ssl_min_protocol = TLSv1.2
EOF

# =====================================================
# 9. Get Let's Encrypt (if DNS resolves)
# =====================================================
echo -e "\n${YELLOW}[9] Attempting Let's Encrypt...${NC}"
systemctl stop nginx 2>/dev/null || true

if certbot certonly --standalone -d ${HOSTNAME} --non-interactive \
    --agree-tos --email ${LE_EMAIL} 2>/dev/null; then
    
    echo "  ✓ SSL certificate obtained"
    
    cat > /etc/dovecot/conf.d/10-ssl.conf <<EOF
ssl = required
ssl_cert = </etc/letsencrypt/live/${HOSTNAME}/fullchain.pem
ssl_key = </etc/letsencrypt/live/${HOSTNAME}/privkey.pem
ssl_min_protocol = TLSv1.2
EOF

    postconf -e "smtpd_tls_cert_file = /etc/letsencrypt/live/${HOSTNAME}/fullchain.pem"
    postconf -e "smtpd_tls_key_file = /etc/letsencrypt/live/${HOSTNAME}/privkey.pem"
    
    # Auto-renewal
    mkdir -p /etc/letsencrypt/renewal-hooks/post
    cat > /etc/letsencrypt/renewal-hooks/post/mail-server.sh <<'EOF'
#!/bin/bash
systemctl restart postfix dovecot nginx
EOF
    chmod +x /etc/letsencrypt/renewal-hooks/post/mail-server.sh
else
    echo "  ⚠ SSL cert failed (DNS may not resolve yet)"
    echo "  Using self-signed certificate"
fi

systemctl start nginx 2>/dev/null || true

# =====================================================
# 10. Setup DKIM
# =====================================================
echo -e "\n${YELLOW}[10] Setting up DKIM...${NC}"
mkdir -p /etc/dkimkeys
chmod 700 /etc/dkimkeys

opendkim-genkey -D /etc/dkimkeys/ -d ${DOMAIN} -s mail -b 2048
chown opendkim:opendkim /etc/dkimkeys/mail.private
chmod 600 /etc/dkimkeys/mail.private

cat > /etc/opendkim.conf <<EOF
Syslog yes
SyslogSuccess yes
LogWhy yes
Domain ${DOMAIN}
Selector mail
KeyFile /etc/dkimkeys/mail.private
Socket inet:8891@localhost
UserID opendkim
Canonicalization relaxed/simple
Mode sv
SubDomains no
AutoRestart yes
AutoRestartRate 10/1M
Background yes
DNSTimeout 5
SignatureAlgorithm rsa-sha256
EOF

cat > /etc/default/opendkim <<'EOF'
RUNC=yes
SOCKET="inet:8891@localhost"
EOF

postconf -e "smtpd_milters = inet:localhost:8891"
postconf -e "non_smtpd_milters = inet:localhost:8891"
postconf -e "milter_default_action = accept"

# =====================================================
# 11. Configure Roundcube
# =====================================================
echo -e "\n${YELLOW}[11] Configuring Roundcube...${NC}"
mkdir -p /var/lib/roundcube
sqlite3 /var/lib/roundcube/roundcube.sqlite < /usr/share/roundcube/SQL/sqlite.initial.sql 2>/dev/null || true
chown -R www-data:www-data /var/lib/roundcube

cat > /etc/roundcube/config.inc.php <<EOF
<?php
\$config = array();
\$config['db_dsnw'] = 'sqlite:////var/lib/roundcube/roundcube.sqlite';
\$config['default_host'] = 'ssl://${HOSTNAME}';
\$config['default_port'] = 993;
\$config['smtp_server'] = 'tls://${HOSTNAME}';
\$config['smtp_port'] = 587;
\$config['smtp_user'] = '%u';
\$config['smtp_pass'] = '%p';
\$config['product_name'] = 'Webmail';
\$config['plugins'] = array('archive', 'zipdownload', 'markasjunk');
\$config['skin'] = 'elastic';
EOF

cat > /etc/nginx/sites-available/roundcube <<EOF
server {
    listen 80;
    server_name webmail.${DOMAIN};
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name webmail.${DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${HOSTNAME}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${HOSTNAME}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    root /var/lib/roundcube;
    index index.php;

    location / {
        try_files \$uri \$uri/ /index.php;
    }

    location ~ \.php\$ {
        include fastcgi_params;
        fastcgi_pass unix:/var/run/php/php-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }
}
EOF

ln -sf /etc/nginx/sites-available/roundcube /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

# =====================================================
# 12. Firewall
# =====================================================
echo -e "\n${YELLOW}[12] Configuring firewall...${NC}"
ufw allow 22/tcp
ufw allow 25/tcp
ufw allow 587/tcp
ufw allow 465/tcp
ufw allow 993/tcp
ufw allow 995/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

# =====================================================
# 13. Start Services
# =====================================================
echo -e "\n${YELLOW}[13] Starting services...${NC}"
systemctl enable postfix dovecot nginx php8.2-fpm opendkim
systemctl restart opendkim
systemctl restart postfix dovecot nginx php8.2-fpm

# =====================================================
# 14. Final Output
# =====================================================
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}   INSTALLATION COMPLETE!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${BLUE}📧 Email Account:${NC}"
echo -e "  Username: ${GREEN}${ADMIN_EMAIL}${NC}"
echo -e "  Password: ${YELLOW}${ADMIN_PASS}${NC}"
echo -e "  ${RED}⚠️  SAVE THIS PASSWORD!${NC}"
echo ""
echo -e "${BLUE}🌐 Webmail:${NC}"
echo -e "  ${GREEN}https://webmail.${DOMAIN}${NC}"
echo ""
echo -e "${BLUE}📨 Email Client Settings:${NC}"
echo -e "  IMAP: ${GREEN}${HOSTNAME}:993${NC} (SSL/TLS)"
echo -e "  SMTP: ${GREEN}${HOSTNAME}:587${NC} (STARTTLS)"
echo -e "  Username: ${GREEN}${ADMIN_EMAIL}${NC}"
echo -e "  Password: ${YELLOW}${ADMIN_PASS}${NC}"
echo ""
echo -e "${BLUE}🔑 DKIM Record (ADD TO CLOUDFLARE):${NC}"
cat /etc/dkimkeys/mail.txt
echo ""
echo -e "${BLUE}📝 SPF Record (ADD TO CLOUDFLARE):${NC}"
echo -e "  ${GREEN}v=spf1 mx ip4:${VPS_IP} -all${NC}"
echo ""
echo -e "${BLUE}📝 DMARC Record (ADD TO CLOUDFLARE):${NC}"
echo -e "  ${GREEN}_dmarc.${DOMAIN} TXT \"v=DMARC1; p=none\"${NC}"
echo ""
echo -e "${BLUE}⚠️  PTR Record (REQUEST FROM VPS PROVIDER):${NC}"
echo -e "  ${GREEN}${VPS_IP} -> ${HOSTNAME}${NC}"
echo ""
echo -e "${GREEN}✓ Test your server:${NC}"
echo -e "  echo 'Test' | mail -s 'Test' ${ADMIN_EMAIL}"
echo ""
echo -e "${RED}⚠️  IMPORTANT: Save this password before closing!${NC}"
echo -e "${YELLOW}Admin Password: ${ADMIN_PASS}${NC}"
echo ""