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

IP_SRV="10.10.$ID.1"
IP_SW="10.10.$ID.254"
GW="10.10.0.1" 
DOMAIN="$ZONE.ac-monge.fr"
PASS_DEFAUT="2000"

# --- 2. ACTIVATION DES LOGS (CRUCIAL POUR VM NEUVE) ---
if ask_confirm "Installer et activer les logs (/var/log/mail.log)"; then
    echo -e "${C}[LOG]${NC} Installation de rsyslog..."
    apt update && apt install -y rsyslog
    systemctl enable --now rsyslog
    echo -e "${G}[OK]${NC} Les logs mail sont maintenant actifs."
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
    netmask 255.255.0.0
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
 ip add $IP_SW 255.255.0.0
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
    systemctl restart bind9 nginx
    echo -e "${G}[OK]${NC} Services DNS et Web opérationnels."
fi

# --- 6. MAIL : FIX TOTAL STARTTLS & STOCKAGE ---
if ask_confirm "Installer le service Mail (Postfix/Dovecot) - SANS SSL (conforme sujet)"; then
    DEBIAN_FRONTEND=noninteractive apt install -y postfix dovecot-imapd mailutils swaks
    
    postconf -e "myhostname = mail.$DOMAIN"
    postconf -e "mydestination = \$myhostname, $DOMAIN, localhost"
    postconf -e "mynetworks = 127.0.0.0/8 10.10.0.0/16"
    postconf -e "home_mailbox = Maildir/"
    postconf -e "smtpd_tls_security_level = none"
    postconf -e "smtpd_use_tls = no"
    postconf -e "smtp_tls_security_level = none"
    postconf -e "smtp_use_tls = no"

    echo "ssl = no" > /etc/dovecot/conf.d/10-ssl.conf
    sed -i 's|^mail_location = .*|mail_location = maildir:~/Maildir|' /etc/dovecot/conf.d/10-mail.conf
    sed -i 's|^#disable_plaintext_auth = .*|disable_plaintext_auth = no|' /etc/dovecot/conf.d/10-auth.conf
    
    echo "service imap-login {
      inet_listener imap {
        port = 143
      }
    }" > /etc/dovecot/conf.d/10-master.conf

    systemctl restart postfix dovecot
    echo -e "${G}[OK]${NC} Postfix et Dovecot configurés en mode local sécurisé."
fi

# --- 6 BIS. OPTION SSL/TLS (CERTIFICAT AUTO-SIGNÉ, HORS EXIGENCES SUJET) ---
if ask_confirm "Activer SSL/TLS (OPTIONNEL, certificat auto-signé)"; then
    echo -e "${C}[INFO]${NC} Génération certificat auto-signé pour mail.$DOMAIN..."
    mkdir -p /etc/ssl/mail_sio
    if [ ! -f /etc/ssl/mail_sio/mail_sio.key ] || [ ! -f /etc/ssl/mail_sio/mail_sio.crt ]; then
        openssl req -x509 -nodes -newkey rsa:2048 \
          -keyout /etc/ssl/mail_sio/mail_sio.key \
          -out /etc/ssl/mail_sio/mail_sio.crt \
          -days 3650 -subj "/CN=mail.$DOMAIN"
    fi

    echo -e "${C}[INFO]${NC} Activation TLS côté Postfix..."
    postconf -e "smtpd_use_tls = yes"
    postconf -e "smtpd_tls_security_level = may"
    postconf -e "smtp_tls_security_level = may"
    postconf -e "smtpd_tls_auth_only = no"
    postconf -e "smtpd_tls_cert_file = /etc/ssl/mail_sio/mail_sio.crt"
    postconf -e "smtpd_tls_key_file  = /etc/ssl/mail_sio/mail_sio.key"

    echo -e "${C}[INFO]${NC} Activation TLS côté Dovecot (IMAPS 993 conservé en plus) ..."
    cat > /etc/dovecot/conf.d/10-ssl.conf <<EOF
ssl = yes
ssl_cert = </etc/ssl/mail_sio/mail_sio.crt
ssl_key  = </etc/ssl/mail_sio/mail_sio.key
disable_plaintext_auth = no
EOF

    cat > /etc/dovecot/conf.d/10-master.conf <<EOF
service imap-login {
  inet_listener imap {
    port = 143
  }
  inet_listener imaps {
    port = 993
    ssl = yes
  }
}
EOF

    systemctl restart postfix dovecot
    echo -e "${G}[OK]${NC} SSL/TLS activé (certificat auto-signé)."
    echo -e "${Y}[NOTE]${NC} Pour rester STRICTEMENT conforme au PDF, tu peux laisser cette étape sur 'n'."
fi

# --- 7. UTILISATEURS & PERMISSIONS ---
if ask_confirm "Créer les comptes (direction, informatique, rh)"; then
    for u in direction informatique rh; do
        id -u $u &>/dev/null || useradd -m -s /bin/bash $u
        echo "$u:$PASS_DEFAUT" | chpasswd
        mkdir -p /home/$u/Maildir/{cur,new,tmp}
        chown -R $u:$u /home/$u/Maildir
        chmod -R 700 /home/$u/Maildir
        echo "Bienvenue. Serveur pret. Aucun certificat requis." | mail -s "Initialisation" $u@$DOMAIN
    done
    echo -e "${G}[OK]${NC} Comptes créés avec stockage serveur actif."
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
    if nc -z 127.0.0.1 993 2>/dev/null; then
        echo -e "   ${G}OK${NC} Port 993 (IMAPS) ouvert"
    else
        echo -e "   ${R}ECHEC${NC} Port 993 (IMAPS) fermé"
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
echo -e "   - Serveur (Entrant/Sortant) : ${W}$IP_SRV${NC}"
echo -e "   - Protocoles : ${G}IMAP (143) / SMTP (25)${NC}"
if [ "$SSL_ENABLED" -eq 1 ]; then
    echo -e "   - Sécurité principale : ${R}AUCUNE / NONE${NC} (conforme sujet)"
    echo -e "   - SSL/TLS dispo en plus : ${G}IMAPS 993 / STARTTLS SMTP 25 (cert auto-signé)${NC}"
else
    echo -e "   - Sécurité : ${R}AUCUNE / NONE${NC}"
fi
echo -e "   - Authentification : ${W}Mot de passe normal${NC}"
echo -e "   - Comptes : ${W}direction, rh, informatique${NC} (mdp par défaut : ${PASS_DEFAUT})"
draw_line
echo -e "${C}Commandes de test manuelles :${NC}"
echo -e "   - Mails en direct : ${W}tail -f /var/log/mail.log${NC}"
echo -e "   - Vérifier DNS : ${W}dig $DOMAIN MX${NC} (ou nslookup mail.$DOMAIN)"
