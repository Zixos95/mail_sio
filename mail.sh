#!/bin/bash

# =================================================================
# TOOLKIT VISUEL & COULEURS
# =================================================================
G='\033[1;32m' # Vert
B='\033[1;34m' # Bleu
Y='\033[1;33m' # Jaune
R='\033[1;31m' # Rouge
C='\033[1;36m' # Cyan
W='\033[1;37m' # Blanc
NC='\033[0m'    # Reset

DEBUG=${DEBUG:-0}
SSL_ENABLED=0

if [ "$DEBUG" -eq 1 ]; then
    set -x
fi

trap 'echo -e "'"${R}[ERREUR]${NC}"' L${LINENO} : ${BASH_COMMAND}" >&2' ERR

draw_line() {
    echo -e "${B}----------------------------------------------------------------${NC}"
}

print_header() {
    clear
    echo -e "${B}################################################################${NC}"
    echo -e "${B}#       DÉPLOIEMENT TOTAL : INFRASTRUCTURE LISE CHARMEL        #${NC}"
    echo -e "${B}#       VERSION : VM NEUVE - ZÉRO ERREUR - NO SSL              #${NC}"
    echo -e "${B}################################################################${NC}"
}

ask_confirm() {
    echo -e "\n${Y}>> $1 ? (o/n)${NC}"
    read -p "Choix : " res
    [[ "$res" == "o" ]]
}

if [ "$EUID" -ne 0 ]; then echo -e "${R}[ERREUR]${NC} root requis"; exit 1; fi

print_header

# --- 1. COLLECTE DES DONNÉES ---
echo -e "${C}[INFO]${NC} Préparation des variables..."
read -p "ID Table (ex: 15) : " ID
read -p "Nom de la zone (ex: erreur404) : " ZONE

echo -e "\n${Y}>> Choix du plan d'adressage ?${NC}"
echo -e "   1) 10.10.x.*   (masque /16 — comme au lycée)"
echo -e "   2) 172.30.x.*  (masque /16)"
echo -e "   3) 192.168.x.* (masque /24 — idéal maison / box sur .1)"
read -p "Choix [1/2/3] (défaut: 1) : " NET_CHOICE

case "${NET_CHOICE:-1}" in
  3)
    NET_A=192
    NET_B=168
    NET_MASK="255.255.255.0"
    ;;
  2)
    NET_A=172
    NET_B=30
    NET_MASK="255.255.0.0"
    ;;
  1|"")
    NET_A=10
    NET_B=10
    NET_MASK="255.255.0.0"
    ;;
  *)
    echo -e "${R}[ERREUR]${NC} Choix réseau invalide: '${NET_CHOICE}' (attendu 1, 2 ou 3)"
    exit 1
    ;;
esac

read -p "Dernier octet IP du serveur (défaut: 1) : " SRV_HOST
SRV_HOST="${SRV_HOST:-1}"
if ! [[ "$SRV_HOST" =~ ^[0-9]+$ ]] || [ "$SRV_HOST" -lt 1 ] || [ "$SRV_HOST" -gt 254 ]; then
    echo -e "${R}[ERREUR]${NC} Octet serveur invalide: '$SRV_HOST' (attendu 1..254)"
    exit 1
fi

IP_SRV="$NET_A.$NET_B.$ID.$SRV_HOST"
IP_SW="$NET_A.$NET_B.$ID.254"
if [ "$NET_A" -eq 172 ] && [ "$NET_B" -eq 30 ]; then
    GW="$NET_A.$NET_B.$ID.254"
elif [ "$NET_A" -eq 192 ] && [ "$NET_B" -eq 168 ]; then
    GW="$NET_A.$NET_B.$ID.1"
else
    GW="$NET_A.$NET_B.0.1"
fi
if [ "$NET_A" -eq 192 ] && [ "$NET_B" -eq 168 ]; then
    LAN_CIDR="$NET_A.$NET_B.$ID.0/24"
else
    LAN_CIDR="$NET_A.$NET_B.0.0/16"
fi
DOMAIN="$ZONE.ac-monge.fr"
PASS_DEFAUT="2000"
USERS_CREATED=""

# --- 2. ACTIVATION DES LOGS (CRUCIAL POUR VM NEUVE) ---
if ask_confirm "Installer et activer les logs (/var/log/mail.log)"; then
    echo -e "${C}[LOG]${NC} Installation de rsyslog..."
    apt update && apt install -y rsyslog
    systemctl enable --now rsyslog
    echo -e "${G}[OK]${NC} Les logs mail sont maintenant actifs."
fi

# --- 2 BIS. SSH (OPTIONNEL) ---
if ask_confirm "Installer SSH (openssh-server) et autoriser l'accès root"; then
    echo -e "${C}[INFO]${NC} Installation de openssh-server..."
    apt update && apt install -y openssh-server
    systemctl enable --now ssh

    mkdir -p /etc/ssh/sshd_config.d
    cat > /etc/ssh/sshd_config.d/99-sio-root.conf <<'EOF'
PermitRootLogin yes
PasswordAuthentication yes
EOF

    systemctl restart ssh
    echo -e "${G}[OK]${NC} SSH installé. Root autorisé (mot de passe)."
fi

# --- 3. CONFIGURATION RÉSEAU ---
if ask_confirm "Configurer l'IP statique ($IP_SRV)"; then
    IFACE=$(ls /sys/class/net | grep -v lo | head -n 1)
    cp /etc/network/interfaces /etc/network/interfaces.bak 2>/dev/null
    cat << EOF > /etc/network/interfaces
auto lo
iface lo inet loopback
auto $IFACE
iface $IFACE inet static
    address $IP_SRV
    netmask $NET_MASK
    gateway $GW
EOF
    echo -e "nameserver 127.0.0.1\nnameserver $GW" > /etc/resolv.conf
    systemctl restart networking
    echo -e "${G}[OK]${NC} Réseau configuré sur $IFACE."
fi

# --- 4. CONFIGURATION SWITCH CISCO ---
print_header
echo -e "${C}[ETAPE]${NC} Commandes Switch Cisco (À copier-coller) :${NC}\n${G}"
cat << EOF
enable
conf t
hostname SW-$ZONE
vlan 10
 name LAN_PROD
 exit
int fa0/1
 sw mode acc
 sw acc vlan 10
 spanning-tree portfast
 exit
int fa0/24
 sw mode acc
 sw acc vlan 10
 exit
int vlan 10
 ip add $IP_SW $NET_MASK
 no shut
 exit
ip default-gateway $GW
exit
wr
EOF
echo -e "${NC}"
read -p "Appuyez sur [ENTRÉE] après avoir configuré le switch..."

# --- 5. DNS & WEB ---
if ask_confirm "Installer DNS (Bind9) et Web (Nginx)"; then
    apt install -y bind9 bind9utils nginx
    echo "zone \"$DOMAIN\" { type master; file \"/etc/bind/db.$DOMAIN\"; };" > /etc/bind/named.conf.local
    cat << EOF > /etc/bind/db.$DOMAIN
\$TTL 604800
@ IN SOA ns.$DOMAIN. admin.$DOMAIN. ( $(date +%Y%m%d)01 604800 86400 2419200 604800 )
@ IN NS ns.$DOMAIN.
@ IN MX 10 mail.$DOMAIN.
@ IN A $IP_SRV
ns IN A $IP_SRV
www IN A $IP_SRV
mail IN A $IP_SRV
EOF
    echo "<h1>Lise Charmel - Production $ZONE</h1>" > /var/www/html/index.html

    # Nginx : répondre sur $DOMAIN et www.$DOMAIN
    cat > "/etc/nginx/sites-available/$DOMAIN.conf" <<EOF
server {
    listen 80;
    server_name $DOMAIN www.$DOMAIN;

    root /var/www/html;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
    ln -sf "/etc/nginx/sites-available/$DOMAIN.conf" "/etc/nginx/sites-enabled/$DOMAIN.conf"
    rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true

    systemctl restart bind9 nginx
    echo -e "${G}[OK]${NC} Services DNS et Web opérationnels."
fi

# --- 6. MAIL : POSTFIX / DOVECOT (sans TLS puis upgrade section 6 bis si demandé) ---
if ask_confirm "Installer le service Mail (Postfix/Dovecot) - SANS SSL (conforme sujet)"; then
    DEBIAN_FRONTEND=noninteractive apt install -y postfix dovecot-imapd mailutils swaks openssl

    postconf -e "myhostname = mail.$DOMAIN"
    postconf -e "mydestination = \$myhostname, $DOMAIN, localhost"
    postconf -e "mynetworks = 127.0.0.0/8 $LAN_CIDR"
    postconf -e "home_mailbox = Maildir/"
    postconf -e "smtpd_tls_security_level = none"
    postconf -e "smtpd_use_tls = no"
    postconf -e "smtp_tls_security_level = none"
    postconf -e "smtp_use_tls = no"

    cat > /etc/dovecot/conf.d/10-ssl.conf <<'DOVEOF'
ssl = no
DOVEOF
    sed -i 's|^mail_location = .*|mail_location = maildir:~/Maildir|' /etc/dovecot/conf.d/10-mail.conf
    sed -i 's|^#disable_plaintext_auth = .*|disable_plaintext_auth = no|' /etc/dovecot/conf.d/10-auth.conf
    sed -i 's|^disable_plaintext_auth = yes|disable_plaintext_auth = no|' /etc/dovecot/conf.d/10-auth.conf 2>/dev/null || true

    rm -f /etc/dovecot/conf.d/99-sio-tls-overlay.conf
    cat > /etc/dovecot/conf.d/99-sio-plain-imaps-off.conf <<'DOVEOF'
service imap-login {
  inet_listener imaps {
    port = 0
  }
}
DOVEOF

    systemctl restart postfix dovecot
    echo -e "${G}[OK]${NC} Postfix et Dovecot : mode sans chiffrement (IMAP 143, SMTP 25)."
fi

# --- 6 BIS. TLS COMPLET (certificat auto-signé + SAN, Postfix STARTTLS + submission, Dovecot IMAPS) ---
if ask_confirm "Activer SSL/TLS complet (certificat auto-signé, hors exigence PDF sujet)"; then
    SSL_ENABLED=1
    echo -e "${C}[INFO]${NC} Génération certificat (SAN: mail, domaine, IP serveur)…"
    mkdir -p /etc/ssl/mail_sio
    chmod 700 /etc/ssl/mail_sio
    OPENSSL_CNF="$(mktemp)"
    cat > "$OPENSSL_CNF" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3_req
prompt = no
encrypt_key = no
[dn]
CN = mail.$DOMAIN
[v3_req]
subjectAltName = @san
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
[san]
DNS.1 = mail.$DOMAIN
DNS.2 = $DOMAIN
DNS.3 = www.$DOMAIN
DNS.4 = localhost
IP.1 = $IP_SRV
IP.2 = 127.0.0.1
EOF
    openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
      -keyout /etc/ssl/mail_sio/mail_sio.key \
      -out /etc/ssl/mail_sio/mail_sio.crt \
      -config "$OPENSSL_CNF" -extensions v3_req
    rm -f "$OPENSSL_CNF"
    chmod 640 /etc/ssl/mail_sio/mail_sio.key
    chmod 644 /etc/ssl/mail_sio/mail_sio.crt
    chown root:root /etc/ssl/mail_sio/mail_sio.key /etc/ssl/mail_sio/mail_sio.crt

    echo -e "${C}[INFO]${NC} Postfix : STARTTLS (25), certificat serveur, protocoles modernes…"
    postconf -e "smtpd_use_tls = yes"
    postconf -e "smtpd_tls_security_level = may"
    postconf -e "smtp_tls_security_level = may"
    postconf -e "smtp_use_tls = yes"
    postconf -e "smtpd_tls_auth_only = no"
    postconf -e "smtpd_tls_cert_file = /etc/ssl/mail_sio/mail_sio.crt"
    postconf -e "smtpd_tls_key_file = /etc/ssl/mail_sio/mail_sio.key"
    postconf -e "smtpd_tls_loglevel = 1"
    postconf -e "smtpd_tls_received_header = yes"
    postconf -e "smtpd_tls_protocols = !SSLv2, !SSLv3, !TLSv1, !TLSv1.1"
    postconf -e "smtp_tls_protocols = !SSLv2, !SSLv3, !TLSv1, !TLSv1.1"
    postconf -e "smtpd_tls_mandatory_protocols = !SSLv2, !SSLv3, !TLSv1, !TLSv1.1"
    postconf -e "tls_medium_cipherlist = ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384"
    postconf -e "smtpd_tls_ciphers = medium"
    postconf -e "smtp_tls_ciphers = medium"

    if grep -qE '^#?submission' /etc/postfix/master.cf; then
        sed -i 's/^#submission/submission/' /etc/postfix/master.cf
    fi
    postconf -P submission/inet/smtpd_tls_security_level=may 2>/dev/null || true
    postconf -P submission/inet/smtpd_client_restrictions=permit_mynetworks,permit_sasl_authenticated,reject 2>/dev/null || true
    postconf -P submission/inet/smtpd_recipient_restrictions=permit_mynetworks,permit_sasl_authenticated,reject_unauth_destination 2>/dev/null || true

    echo -e "${C}[INFO]${NC} Dovecot : TLS 1.2+, IMAPS 993, STARTTLS possible sur 143…"
    rm -f /etc/dovecot/conf.d/99-sio-plain-imaps-off.conf
    {
      echo "ssl = yes"
      echo "ssl_cert = </etc/ssl/mail_sio/mail_sio.crt"
      echo "ssl_key = </etc/ssl/mail_sio/mail_sio.key"
      echo "ssl_min_protocol = TLSv1.2"
      echo "ssl_prefer_server_ciphers = yes"
      if [ -r /usr/share/dovecot/dh.pem ]; then
        echo "ssl_dh = </usr/share/dovecot/dh.pem"
      fi
    } > /etc/dovecot/conf.d/10-ssl.conf
    rm -f /etc/dovecot/conf.d/99-sio-tls-overlay.conf
    sed -i 's/^disable_plaintext_auth = yes/disable_plaintext_auth = no/' /etc/dovecot/conf.d/10-auth.conf 2>/dev/null || true
    sed -i 's/^#disable_plaintext_auth = yes/disable_plaintext_auth = no/' /etc/dovecot/conf.d/10-auth.conf 2>/dev/null || true

    if ! postfix check; then
        echo -e "${R}[ERREUR]${NC} postfix check a échoué."
    fi
    if ! doveconf -n >/dev/null 2>&1; then
        echo -e "${R}[ERREUR]${NC} doveconf -n signale une erreur — vérifie la config Dovecot."
    fi

    systemctl restart postfix dovecot

    echo -e "${G}[OK]${NC} TLS activé : cert ${W}/etc/ssl/mail_sio/${NC}, Postfix STARTTLS + submission 587, Dovecot IMAPS 993."
    echo -e "${Y}Vérifs rapides :${NC} ${W}openssl s_client -connect 127.0.0.1:993 -servername mail.$DOMAIN -brief${NC}"
    echo -e "  ${W}openssl s_client -connect 127.0.0.1:25 -starttls smtp -brief${NC}"
    echo -e "${Y}[NOTE]${NC} Certificat auto-signé : Thunderbird demandera une exception de confiance."
    echo -e "${Y}[NOTE]${NC} Pour rester strictement conforme au PDF sans chiffrement, refuse cette étape."
fi

# --- 7. UTILISATEURS & PERMISSIONS ---
if ask_confirm "Créer des comptes utilisateurs (plusieurs possibles)"; then
    echo -e "${Y}>> Saisis les noms d'utilisateurs à créer (séparés par espaces ou virgules).${NC}"
    read -p "Utilisateurs (ex: direction,rh,informatique) : " USERS_INPUT
    USERS_INPUT="${USERS_INPUT//,/ }"

    for u in $USERS_INPUT; do
        [ -z "$u" ] && continue
        if ! [[ "$u" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
            echo -e "${R}[ERREUR]${NC} Nom utilisateur invalide: '$u' (utilise lettres/chiffres/_-)"
            continue
        fi

        id -u "$u" &>/dev/null || useradd -m -s /bin/bash "$u"
        echo "$u:$PASS_DEFAUT" | chpasswd
        mkdir -p "/home/$u/Maildir/cur" "/home/$u/Maildir/new" "/home/$u/Maildir/tmp"
        chown -R "$u:$u" "/home/$u/Maildir"
        chmod -R 700 "/home/$u/Maildir"
        echo "Bienvenue. Serveur pret. Aucun certificat requis." | mail -s "Initialisation" "$u@$DOMAIN" || true

        if [ -z "$USERS_CREATED" ]; then
            USERS_CREATED="$u"
        else
            USERS_CREATED="$USERS_CREATED, $u"
        fi
    done

    if [ -n "$USERS_CREATED" ]; then
        echo -e "${G}[OK]${NC} Comptes créés : ${W}$USERS_CREATED${NC} (mdp : ${PASS_DEFAUT})"
    else
        echo -e "${Y}[INFO]${NC} Aucun compte créé."
    fi
fi

# --- 8. TESTS AUTOMATIQUES (DNS / SMTP / IMAP) ---
echo -e "${C}[TEST]${NC} Lancement des vérifications automatiques..."

echo -e "${Y}- Test DNS (A + MX) pour ${DOMAIN}${NC}"
if command -v dig >/dev/null 2>&1; then
    dig "$DOMAIN" A +short || true
    dig "$DOMAIN" MX +short || true
else
    nslookup mail."$DOMAIN" || true
fi

echo -e "${Y}- Test des ports SMTP/IMAP en local${NC}"
for port in 25 143; do
    if nc -z 127.0.0.1 "$port" 2>/dev/null; then
        echo -e "   ${G}OK${NC} Port $port ouvert"
    else
        echo -e "   ${R}ECHEC${NC} Port $port fermé"
    fi
done

if [ "$SSL_ENABLED" -eq 1 ]; then
    for port in 993 587; do
        if nc -z 127.0.0.1 "$port" 2>/dev/null; then
            echo -e "   ${G}OK${NC} Port $port ouvert (TLS: IMAPS ou submission)"
        else
            echo -e "   ${R}ECHEC${NC} Port $port fermé"
        fi
    done
    echo -e "${Y}- Poignée TLS (openssl, en local)${NC}"
    if command -v openssl >/dev/null 2>&1; then
        echo -e "   IMAPS : ${W}openssl s_client -connect 127.0.0.1:993 -servername mail.$DOMAIN -brief </dev/null 2>&1 | head -3${NC}"
        echo -e "   SMTP+STARTTLS : ${W}echo QUIT | openssl s_client -connect 127.0.0.1:25 -starttls smtp -brief 2>&1 | head -5${NC}"
    fi
fi

echo -e "${Y}- Test envoi mail local (direction -> rh)${NC}"
if command -v swaks >/dev/null 2>&1; then
    swaks --server 127.0.0.1 --port 25 \
        --from "direction@$DOMAIN" \
        --to "rh@$DOMAIN" \
        --header "Subject: TEST_AUTO_SIO" \
        --body "Test automatique OK (direction -> rh)" \
        --quit-after DATA >/tmp/test_mail_sio.log 2>&1 || true
    echo -e "   ${G}Voir /tmp/test_mail_sio.log pour le détail SMTP.${NC}"
else
    echo -e "   ${R}swaks non installé${NC} (test SMTP détaillé ignoré)."
fi

echo -e "${Y}- Vérification rapide des logs mail${NC}"
if [ -f /var/log/mail.log ]; then
    echo -e "   ${W}Dernières lignes :${NC}"
    tail -n 5 /var/log/mail.log || true
else
    echo -e "   ${R}/var/log/mail.log introuvable.${NC}"
fi

# --- RÉSUMÉ FINAL ---
print_header
echo -e "${G}DÉPLOIEMENT RÉUSSI !${NC}"
draw_line
echo -e "${Y}INFOS THUNDERBIRD (PARAMÈTRES MANUELS) :${NC}"
echo -e "   - Nom de compte (email) : ${W}<utilisateur>@$DOMAIN${NC}  (ex: ${W}direction@$DOMAIN${NC})"
echo -e "   - Identifiant (login)   : ${W}<utilisateur>${NC}  (ex: ${W}direction${NC})"
echo -e "   - Serveur entrant       : ${W}mail.$DOMAIN${NC}  (ou ${W}$IP_SRV${NC} si pas de DNS)"
echo -e "   - Protocole entrant     : ${G}IMAP${NC}"
echo -e "   - Port IMAP             : ${W}143${NC}"
echo -e "   - Sécurité IMAP         : ${R}Aucune${NC}"
echo -e "   - Authentification IMAP : ${W}Mot de passe normal${NC}"
echo -e "   - Serveur sortant (SMTP): ${W}mail.$DOMAIN${NC}  (ou ${W}$IP_SRV${NC})"
echo -e "   - Port SMTP             : ${W}25${NC}"
echo -e "   - Sécurité SMTP         : ${R}Aucune${NC}"
echo -e "   - Authentification SMTP : ${W}Mot de passe normal${NC}"
if [ "$SSL_ENABLED" -eq 1 ]; then
    echo -e "   - ${G}TLS activé${NC} (cert auto-signé ${W}/etc/ssl/mail_sio/${NC}) :"
    echo -e "       - IMAP : ${W}SSL/TLS${NC} + port ${W}993${NC} (recommandé) ${Y}ou${NC} port 143 + STARTTLS"
    echo -e "       - SMTP : port ${W}587${NC} (STARTTLS) ${Y}ou${NC} ${W}25${NC} + STARTTLS"
    echo -e "       - Thunderbird : accepter l’${Y}exception de sécurité${NC} (certificat non reconnu)"
    echo -e "       - Vérif serveur : ${W}postconf | grep smtpd_tls_cert${NC} ; ${W}doveconf -n | grep ssl_cert${NC}"
else
    echo -e "   - Sécurité : ${R}AUCUNE / NONE${NC} (conforme sujet)"
fi
if [ -n "$USERS_CREATED" ]; then
    echo -e "   - Comptes : ${W}$USERS_CREATED${NC} (mdp par défaut : ${PASS_DEFAUT})"
else
    echo -e "   - Comptes : ${W}(non renseigné ici)${NC} (mdp par défaut : ${PASS_DEFAUT})"
fi
draw_line
echo -e "${C}Commandes de test manuelles :${NC}"
echo -e "   - Mails en direct : ${W}tail -f /var/log/mail.log${NC}"
echo -e "   - Vérifier DNS : ${W}dig $DOMAIN MX${NC} (ou nslookup mail.$DOMAIN)"

draw_line
echo -e "${Y}CONFIG RÉSEAU PC DE TEST (À METTRE EN STATIQUE) :${NC}"
echo -e "   - IP (exemple) : ${W}$NET_A.$NET_B.$ID.10${NC}"
echo -e "   - Masque      : ${W}$NET_MASK${NC} ${Y}(${LAN_CIDR})${NC}"
echo -e "   - Passerelle  : ${W}$GW${NC}"
echo -e "   - DNS         : ${W}$IP_SRV${NC}  (le serveur fait DNS + WEB + MAIL)"
echo -e "   - Domaine     : ${W}$DOMAIN${NC}"

echo -e "\n${Y}RÉSULTATS ATTENDUS (DEPUIS LE PC DE TEST) :${NC}"
echo -e "${W}1) Vérifier que le DNS pointe sur le serveur${NC}"
echo -e "   - Commande : ${G}nslookup mail.$DOMAIN${NC}"
echo -e "   - Attendu  : ${W}Address: $IP_SRV${NC}"
echo -e "   - Commande : ${G}nslookup -type=mx $DOMAIN${NC}"
echo -e "   - Attendu  : ${W}$DOMAIN mail.$DOMAIN${NC} (ou équivalent MX -> mail.$DOMAIN)"

echo -e "\n${W}2) Vérifier l'accès WEB via nom (donc via DNS)${NC}"
echo -e "   - Commande : ${G}nslookup www.$DOMAIN${NC}"
echo -e "   - Attendu  : ${W}Address: $IP_SRV${NC}"
echo -e "   - Commande : ${G}curl -s http://www.$DOMAIN | head${NC}"
echo -e "   - Attendu  : ${W}<h1>Lise Charmel - Production $ZONE</h1>${NC}"
echo -e "   - Sinon : ouvrir ${W}http://www.$DOMAIN${NC} dans un navigateur"

echo -e "\n${W}3) Vérifier la connectivité IP (si besoin)${NC}"
echo -e "   - Commande : ${G}ping -c 2 $IP_SRV${NC}"
echo -e "   - Attendu  : ${W}2 réponses${NC}"

echo -e "\n${Y}IMPORTANT (plan d'adressage) :${NC}"
if [ "$NET_A" -eq 192 ] && [ "$NET_B" -eq 168 ]; then
    echo -e "   - Plan ${W}192.168${NC} : sous-réseau ${W}$LAN_CIDR${NC}, passerelle type box ${W}$GW${NC}."
    echo -e "   - Mets ton PC dans ${W}$NET_A.$NET_B.$ID.x${NC} avec le même masque ${W}$NET_MASK${NC}."
else
    echo -e "   - Avec un masque ${W}/16${NC}, ton PC (${W}$NET_A.$NET_B.$ID.x${NC}) et le serveur (${W}$IP_SRV${NC})"
    echo -e "     sont dans le même réseau ${W}$NET_A.$NET_B.0.0/16${NC} -> accès direct OK."
    echo -e "   - Si tu mets un masque ${R}/24${NC}, le PC serait dans ${W}$NET_A.$NET_B.$ID.0/24${NC} et le serveur dans ${W}$NET_A.$NET_B.$ID.0/24${NC} (ça peut marcher),"
    echo -e "     mais tout ce qui est hors ${W}$NET_A.$NET_B.$ID.*${NC} (ex: passerelle ${W}$GW${NC}) dépendra du routage."
fi
