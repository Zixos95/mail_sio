#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$' \t\n'

SCRIPT_NAME="$(basename "$0")"

DOMAIN="${DOMAIN:-erreur404.ac-monge.fr}"
SERVER_IP="${SERVER_IP:-10.10.15.2}"
HOST_FQDN="${HOST_FQDN:-mail.${DOMAIN}}"

INTERACTIVE="${INTERACTIVE:-1}"

LOCAL_USERS_RAW="${LOCAL_USERS:-alice bob}"
DEFAULT_USER_PASSWORD="${DEFAULT_USER_PASSWORD:-SioMail2026!}"
SSL_ENABLED="${SSL_ENABLED:-0}"

MYNETWORKS="${MYNETWORKS:-127.0.0.0/8,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16}"
RUN_FIREWALL="${RUN_FIREWALL:-0}"

REMOTE_TEST_EMAIL="${REMOTE_TEST_EMAIL:-}"
REMOTE_TEST_SENDER="${REMOTE_TEST_SENDER:-}"
REMOTE_TEST_SMTP_HOST="${REMOTE_TEST_SMTP_HOST:-}"
REMOTE_TEST_SMTP_PORT="${REMOTE_TEST_SMTP_PORT:-25}"

WORKDIR="${WORKDIR:-/tmp/mail-isole}"
LOG_FILE="${LOG_FILE:-$WORKDIR/${SCRIPT_NAME%.sh}.log}"

mkdir -p "$WORKDIR"
touch "$LOG_FILE"

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE" >/dev/null || true
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

on_err() {
  local line="${1:-$LINENO}"
  local cmd="${2:-$BASH_COMMAND}"
  log "ERREUR: ${SCRIPT_NAME} a echoue (ligne: ${line})."
  log "Commande en echec: ${cmd}"
  log "Voir le journal complet: ${LOG_FILE:-non_defini}"
}
trap 'on_err "$LINENO" "$BASH_COMMAND"' ERR

is_tty() {
  [[ -t 0 && -t 1 ]]
}

prompt_if_interactive() {
  local varname="$1"
  local question="$2"
  local default_value="${3:-}"

  if [[ "$(is_tty && echo 1 || echo 0)" == "0" ]]; then
    return 0
  fi
  if [[ "$INTERACTIVE" != "1" ]]; then
    return 0
  fi

  local answer=""
  if [[ -n "$default_value" ]]; then
    printf '%s [%s] : ' "$question" "$default_value"
    read -r answer || true
    answer="${answer:-$default_value}"
  else
    printf '%s : ' "$question"
    read -r answer || true
  fi
  printf -v "$varname" '%s' "$answer"
  export "$varname"
}

prompt_bool_if_interactive() {
  local varname="$1"
  local question="$2"
  local default_value="${3:-0}"

  if [[ "$(is_tty && echo 1 || echo 0)" == "0" ]]; then
    return 0
  fi
  if [[ "$INTERACTIVE" != "1" ]]; then
    return 0
  fi

  local answer=""
  printf '%s [0=non, 1=oui] [%s] : ' "$question" "$default_value"
  read -r answer || true
  answer="${answer:-$default_value}"
  case "$answer" in
    1|true|yes|oui|o|y) answer=1 ;;
    0|false|no|non|n) answer=0 ;;
    *) answer="$default_value" ;;
  esac
  printf -v "$varname" '%s' "$answer"
  export "$varname"
}

interactive_setup() {
  prompt_if_interactive DOMAIN "Domaine DNS interne" "${DOMAIN}"
  prompt_if_interactive SERVER_IP "IP du serveur (Bind9 + mail)" "${SERVER_IP}"
  prompt_if_interactive HOST_FQDN "Nom FQDN du serveur mail" "${HOST_FQDN}"
  prompt_if_interactive LOCAL_USERS "Utilisateurs locaux (séparés par espace)" "${LOCAL_USERS_RAW}"
  prompt_if_interactive DEFAULT_USER_PASSWORD "Mot de passe test (IMAP en clair)" "${DEFAULT_USER_PASSWORD}"
  prompt_if_interactive MYNETWORKS "Plages mynetworks SMTP (liste séparée par virgule)" "${MYNETWORKS}"
  prompt_if_interactive RUN_FIREWALL "Activer firewall ufw (0=non, 1=oui)" "${RUN_FIREWALL}"
  prompt_bool_if_interactive SSL_ENABLED "Activer TLS/SSL (labo, auto-signé)" "${SSL_ENABLED}"

  prompt_if_interactive REMOTE_TEST_EMAIL "Email distant de test (vide = ignorer)" "${REMOTE_TEST_EMAIL}"
  prompt_if_interactive REMOTE_TEST_SENDER "Expéditeur distant (vide = auto)" "${REMOTE_TEST_SENDER}"
  prompt_if_interactive REMOTE_TEST_SMTP_HOST "Serveur SMTP distant (vide = envoyer via serveur local)" "${REMOTE_TEST_SMTP_HOST}"
  prompt_if_interactive REMOTE_TEST_SMTP_PORT "Port SMTP distant" "${REMOTE_TEST_SMTP_PORT}"

  prompt_if_interactive WORKDIR "Dossier de travail/logs" "${WORKDIR}"
}

CERT_DIR="${CERT_DIR:-/etc/ssl/mail-isole}"
TLS_CERT_FILE="${TLS_CERT_FILE:-$CERT_DIR/mail-isole.crt}"
TLS_KEY_FILE="${TLS_KEY_FILE:-$CERT_DIR/mail-isole.key}"

generate_ssl_certs() {
  if [[ "${SSL_ENABLED}" != "1" ]]; then
    return 0
  fi

  log "SSL: generation certificats auto-signes (labo)..."
  mkdir -p "$CERT_DIR"

  if [[ -f "$TLS_CERT_FILE" && -f "$TLS_KEY_FILE" ]]; then
    log "SSL: certificats deja presents: $TLS_CERT_FILE"
    return 0
  fi

  openssl req -x509 -nodes -newkey rsa:2048 \
    -keyout "$TLS_KEY_FILE" -out "$TLS_CERT_FILE" \
    -days 3650 -subj "/CN=${HOST_FQDN}" 2>&1 | tee -a "$LOG_FILE"
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
      exec sudo -E bash "$0" "$@"
    else
      echo "Ce script doit etre execute en root (sudo requis)."
      exit 1
    fi
  fi
}

ensure_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    log "Commande manquante: $cmd"
    return 1
  fi
}

apt_install() {
  log "Installation des paquets necessaires..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y --no-install-recommends "$@"
}

systemctl_safe_restart() {
  local svc="$1"
  log "Redemarrage du service: $svc"
  systemctl enable "$svc" >/dev/null 2>&1 || true
  systemctl restart "$svc"
}

parse_users() {
  LOCAL_USERS_RAW="${LOCAL_USERS:-alice bob}"
  LOCAL_USERS=($LOCAL_USERS_RAW)
  if ((${#LOCAL_USERS[@]} < 1)); then
    log "LOCAL_USERS est vide: au moins 1 utilisateur est requis."
    exit 1
  fi
}

create_local_users() {
  log "Creation/initialisation des utilisateurs systeme..."
  for u in "${LOCAL_USERS[@]}"; do
    if ! id "$u" >/dev/null 2>&1; then
      log "Creation user systeme: $u"
      useradd -m -s /bin/bash "$u"
    else
      log "User existe deja: $u"
    fi

    echo "${u}:${DEFAULT_USER_PASSWORD}" | chpasswd

    local home_dir
    home_dir="$(getent passwd "$u" | cut -d: -f6 || true)"
    [[ -n "$home_dir" ]] || home_dir="/home/${u}"

    local group_name
    group_name="$(id -gn "$u" 2>/dev/null || echo "$u")"

    mkdir -p "$home_dir"

    install -d -m 0750 -o "$u" -g "$group_name" "${home_dir}/Maildir"
    install -d -m 0700 -o "$u" -g "$group_name" "${home_dir}/Maildir/cur"
    install -d -m 0700 -o "$u" -g "$group_name" "${home_dir}/Maildir/new"
    install -d -m 0700 -o "$u" -g "$group_name" "${home_dir}/Maildir/tmp"
  done
}

configure_postfix() {
  log "Configuration Postfix..."

  postconf -e "myhostname=${HOST_FQDN}"
  postconf -e "myorigin=${DOMAIN}"
  postconf -e "mydomain=${DOMAIN}"
  postconf -e "mydestination=${HOST_FQDN},localhost.${DOMAIN},localhost,${DOMAIN}"
  postconf -e "inet_interfaces=all"
  postconf -e "inet_protocols=all"

  postconf -e "home_mailbox=Maildir/"
  postconf -e "mailbox_size_limit=0"

  postconf -e "mynetworks=${MYNETWORKS}"

  if [[ "${SSL_ENABLED}" == "1" ]]; then
    postconf -e "smtpd_use_tls=yes"
    postconf -e "smtpd_tls_security_level=may"
    postconf -e "smtpd_tls_auth_only=no"
    postconf -e "smtpd_sasl_auth_enable=no"
    postconf -e "smtpd_tls_cert_file=${TLS_CERT_FILE}"
    postconf -e "smtpd_tls_key_file=${TLS_KEY_FILE}"
  else
    postconf -e "smtpd_tls_security_level=none"
    postconf -e "smtpd_use_tls=no"
    postconf -e "smtpd_tls_auth_only=no"
    postconf -e "smtpd_sasl_auth_enable=no"
  fi

  postconf -e "smtpd_relay_restrictions=permit_mynetworks,reject"

  if [[ "${POSTFIX_DEBUG:-0}" == "1" ]]; then
    postconf -e "debug_peer_level=2"
    postconf -e "debugger_command=echo \$daemon_name \$process_id"
  fi
}

configure_dovecot() {
  log "Configuration Dovecot..."
  ensure_cmd doveconf || true

  local conf="/etc/dovecot/conf.d/99-mail-isole.conf"
  cp -a "$conf" "${conf}.bak.$(date '+%Y%m%d-%H%M%S')" 2>/dev/null || true

  if [[ "${SSL_ENABLED}" == "1" ]]; then
    cat >"$conf" <<EOF
protocols = imap imaps
ssl = yes
ssl_cert = <${TLS_CERT_FILE}
ssl_key = <${TLS_KEY_FILE}
disable_plaintext_auth = no
auth_mechanisms = plain login
mail_location = maildir:/home/%u/Maildir
passdb { driver = pam }
userdb { driver = passwd }
EOF
  else
    cat >"$conf" <<EOF
protocols = imap
ssl = no
disable_plaintext_auth = no
auth_mechanisms = plain login
mail_location = maildir:/home/%u/Maildir
passdb {
  driver = pam
}
userdb {
  driver = passwd
}
EOF
  fi
}

configure_bind9() {
  log "Configuration Bind9 (DNS autoritaire)..."

  local zone_file="/etc/bind/zones/db.${DOMAIN}"
  mkdir -p "/etc/bind/zones"

  cat >"$zone_file" <<EOF
\$TTL 3600
@ IN SOA ns1.${DOMAIN}. hostmaster.${DOMAIN}. (
  2026042901 ; serial
  3600        ; refresh
  1800        ; retry
  604800      ; expire
  600         ; minimum
)

@   IN NS  ${HOST_FQDN}.
@   IN A   ${SERVER_IP}
mail IN A  ${SERVER_IP}
@   IN MX  10 ${HOST_FQDN}.
EOF

  chmod 0644 "$zone_file"

  local named_local="/etc/bind/named.conf.local"
  cp -a "$named_local" "${named_local}.bak.$(date '+%Y%m%d-%H%M%S')" 2>/dev/null || true

  if grep -qF "zone \"${DOMAIN}\"" "$named_local"; then
    log "Zone ${DOMAIN} deja declaree dans ${named_local}."
  else
    cat >>"$named_local" <<EOF

zone "${DOMAIN}" {
  type master;
  file "${zone_file}";
  allow-query { any; };
  allow-transfer { none; };
};
EOF
    log "Zone ${DOMAIN} ajoutee a ${named_local}."
  fi

  local named_options="/etc/bind/named.conf.options"
  if [[ -f "$named_options" ]]; then
    cp -a "$named_options" "${named_options}.bak.$(date '+%Y%m%d-%H%M%S')" 2>/dev/null || true
    if grep -Eq "recursion[[:space:]]+" "$named_options"; then
      sed -i 's/recursion\s\+.*/recursion no;/' "$named_options"
    else
      echo "recursion no;" >>"$named_options"
    fi
  fi
}

configure_firewall_optional() {
  if [[ "$RUN_FIREWALL" != "1" ]]; then
    log "Firewall: desactive (RUN_FIREWALL=0)."
    return 0
  fi

  if ! command -v ufw >/dev/null 2>&1; then
    log "Firewall: ufw non installe; on saute."
    return 0
  fi

  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing

  ufw allow 53/tcp
  ufw allow 53/udp
  ufw allow 25/tcp
  ufw allow 143/tcp
  if [[ "${SSL_ENABLED}" == "1" ]]; then
    ufw allow 993/tcp
  fi

  ufw --force enable
}

check_services_active() {
  log "Verification services..."
  for svc in bind9 postfix dovecot; do
    if systemctl list-unit-files 2>/dev/null | grep -qE "^${svc//./\\.}\.service$"; then
      systemctl is-active --quiet "$svc"
      log "OK: $svc actif"
    else
      log "Attention: service $svc introuvable (peut etre module)."
    fi
  done
}

named_checks() {
  if command -v named-checkconf >/dev/null 2>&1; then
    log "named-checkconf:"
    named-checkconf 2>&1 | tee -a "$LOG_FILE"
  fi

  if command -v named-checkzone >/dev/null 2>&1; then
    log "named-checkzone ${DOMAIN}:"
    named-checkzone "${DOMAIN}" "/etc/bind/zones/db.${DOMAIN}" 2>&1 | tee -a "$LOG_FILE"
  fi
}

postfix_checks() {
  log "postconf -n (postfix final):"
  postconf -n 2>&1 | tee -a "$LOG_FILE"
}

dovecot_checks() {
  log "doveconf -n (dovecot final):"
  if command -v doveconf >/dev/null 2>&1; then
    doveconf -n 2>&1 | tee -a "$LOG_FILE"
  else
    log "doveconf indisponible."
  fi
}

run_dns_tests() {
  local server="127.0.0.1"
  log "Tests DNS (dig sur serveur local):"
  run_capture "A domain ${DOMAIN}" dig @"$server" "$DOMAIN" A +noall +answer
  run_capture "MX domain ${DOMAIN}" dig @"$server" "$DOMAIN" MX +noall +answer
  run_capture "A host ${HOST_FQDN}" dig @"$server" "$HOST_FQDN" A +noall +answer
}

run_capture() {
  local desc="$1"; shift
  log "TEST: ${desc}"
  set +e
  local output
  output="$("$@" 2>&1)"
  local rc=$?
  printf "%s\n" "$output" | tee -a "$LOG_FILE"
  if [[ $rc -eq 0 ]]; then
    log "RESULTAT: OK"
  else
    log "RESULTAT: ECHEC (code $rc)"
  fi
  set -e
  return 0
}

run_smtp_test_local() {
  local sender="${LOCAL_USERS[0]}"
  local recipient="${LOCAL_USERS[1]:-${LOCAL_USERS[0]}}"
  local sender_email="${sender}@${DOMAIN}"
  local recipient_email="${recipient}@${DOMAIN}"

  log "Test SMTP local (envoi via Postfix vers ${recipient_email})..."

  ensure_cmd swaks || true
  if ! command -v swaks >/dev/null 2>&1; then
    log "swaks absent: installation attendue avant tests."
    return 1
  fi

  rm -f "/home/${recipient}/Maildir/new/"* 2>/dev/null || true

  run_capture "Port SMTP 25 ouvert" nc -z 127.0.0.1 25

  if [[ "${SSL_ENABLED}" == "1" ]]; then
    run_capture "SMTP STARTTLS annonce (EHLO contient STARTTLS)" \
      bash -lc "printf 'EHLO test\\r\\nQUIT\\r\\n' | nc -w 2 127.0.0.1 25 2>/dev/null | tr -d '\\r' | grep -q STARTTLS"
  fi

  local subject="Test SMTP/IMAP (SIO)"
  local data="Subject: ${subject}
From: ${sender_email}
To: ${recipient_email}
Date: $(date -R)

Bonjour,
Ceci est un test d'envoi local SMTP -> livraison Maildir.

Fin de test."

  run_capture "Envoi SWAKS" \
    swaks --server 127.0.0.1 --port 25 \
      --from "${sender_email}" \
      --to "${recipient_email}" \
      --auth-user "unused" --auth-password "unused" \
      --no-ssl \
      --quit-after DATA \
      --data "$data"

  sleep 2

  log "Verification livraison (existence message dans Maildir/new):"
  run_capture "Maildir new entries pour ${recipient}" \
    bash -lc "ls -1 /home/${recipient}/Maildir/new 2>/dev/null | wc -l"

  run_capture "mailq (queue postfix)" mailq

  log "Nombre de messages (Maildir/new):"
  bash -lc "ls -1 /home/${recipient}/Maildir/new 2>/dev/null | sed -n '1,20p' | tee -a \"$LOG_FILE\"" || true
}

run_imap_auth_test_local() {
  local port="${1:-143}"
  local use_ssl="${2:-0}"
  local label="${3:-IMAP}"

  local user="${LOCAL_USERS[0]}"
  local pass="${DEFAULT_USER_PASSWORD}"

  log "Test ${label} (user=${user}, use_ssl=${use_ssl})..."
  run_capture "Port IMAP ${port} ouvert" nc -z 127.0.0.1 "${port}"

  set +e
  IMAP_USER="${user}" IMAP_PASS="${pass}" IMAP_PORT="${port}" IMAP_USE_SSL="${use_ssl}" \
  python3 - <<'PY' 2>&1 | tee -a "$LOG_FILE"
import imaplib, os, sys, ssl
user = os.environ.get("IMAP_USER")
pw = os.environ.get("IMAP_PASS")
port = int(os.environ.get("IMAP_PORT", "143"))
use_ssl = os.environ.get("IMAP_USE_SSL", "0") == "1"
host = "127.0.0.1"
try:
    if use_ssl:
        ctx = ssl._create_unverified_context()
        M = imaplib.IMAP4_SSL(host, port, ssl_context=ctx)
    else:
        M = imaplib.IMAP4(host, port)
    typ, data = M.login(user, pw)
    typ2, boxes = M.list()
    print("LOGIN typ:", typ, "data:", data)
    print("LIST typ:", typ2)
    print("LIST sample:", (boxes or [])[:5])
    M.logout()
    sys.exit(0)
except Exception as e:
    print("IMAP test exception:", repr(e))
    sys.exit(1)
PY
  local rc=$?
  if [[ $rc -eq 0 ]]; then
    log "${label}: RESULTAT OK"
  else
    log "${label}: RESULTAT ECHEC (code ${rc})"
  fi
  set -e
  return 0
}

run_remote_test_optional() {
  if [[ -z "${REMOTE_TEST_EMAIL}" ]]; then
    log "Test distant: ignore (REMOTE_TEST_EMAIL non defini)."
    return 0
  fi

  local sender="${REMOTE_TEST_SENDER:-${LOCAL_USERS[0]}@${DOMAIN}}"
  local to="${REMOTE_TEST_EMAIL}"

  log "Test distant (optionnel): envoi vers ${to}"
  rm -f "/home/${LOCAL_USERS[0]}/Maildir/new/"* 2>/dev/null || true

  local data="Subject: Test distant SMTP (SIO)
From: ${sender}
To: ${to}
Date: $(date -R)

Bonjour,
Test envoye par le script de mise en place mail-isole.
"

  if [[ -n "${REMOTE_TEST_SMTP_HOST}" ]]; then
    run_capture "SWAKS vers serveur SMTP distant" \
      swaks --server "${REMOTE_TEST_SMTP_HOST}" --port "${REMOTE_TEST_SMTP_PORT}" \
        --from "${sender}" --to "${to}" --no-ssl --quit-after DATA --data "$data"
  else
    run_capture "SWAKS via notre serveur local" \
      swaks --server 127.0.0.1 --port 25 \
        --from "${sender}" --to "${to}" --no-ssl --quit-after DATA --data "$data"
  fi
}

main() {
  interactive_setup
  require_root
  parse_users

  log "=== ${SCRIPT_NAME} demarre ==="
  log "Domaine: ${DOMAIN}"
  log "Serveur mail: ${HOST_FQDN} (${SERVER_IP})"
  log "Users locaux: ${LOCAL_USERS[*]}"
  log "Mot de passe: (voir fin de script / tests)"

  apt_install \
    postfix \
    dovecot-imapd \
    bind9 \
    bind9utils \
    dnsutils \
    netcat-openbsd \
    swaks \
    python3 \
    openssl

  generate_ssl_certs

  create_local_users
  configure_postfix
  configure_dovecot
  configure_bind9
  configure_firewall_optional

  systemctl_safe_restart "bind9"
  systemctl_safe_restart "postfix"
  systemctl_safe_restart "dovecot"

  named_checks
  postfix_checks
  dovecot_checks
  check_services_active

  log "=== Lancement des tests ==="
  run_dns_tests
  run_smtp_test_local

  run_imap_auth_test_local 143 0 "IMAP (no-SSL)"
  if [[ "${SSL_ENABLED}" == "1" ]]; then
    run_imap_auth_test_local 993 1 "IMAPS (SSL)"
  fi

  run_remote_test_optional || true

  log "=== Fin: resume tests ==="
  log "Journal complet: $LOG_FILE"

  echo
  echo "Credentials (pour tests IMAP/Thunderbird):"
  if [[ "${SSL_ENABLED}" == "1" ]]; then
    echo "  Serveur IMAPS: ${HOST_FQDN} port 993 (SSL/TLS)"
    echo "  Serveur IMAP:  ${HOST_FQDN} port 143 (no-SSL, optionnel)"
    echo "  Serveur SMTP: ${HOST_FQDN} port 25 (STARTTLS optionnel)"
  else
    echo "  Serveur IMAP: ${HOST_FQDN} port 143 (pas de SSL)"
    echo "  Serveur SMTP: ${HOST_FQDN} port 25 (pas de SSL)"
  fi
  for u in "${LOCAL_USERS[@]}"; do
    echo "  - ${u} / ${DEFAULT_USER_PASSWORD}"
  done
  echo
  echo "Procedure rapide (a verifier):"
  echo "  1) DNS: dig @127.0.0.1 ${DOMAIN} A + MX"
  echo "  2) SMTP: swaks envoi local + mailq"
  if [[ "${SSL_ENABLED}" == "1" ]]; then
    echo "  3) IMAP: connexion sur port 143 et login en clair"
    echo "  4) IMAPS: connexion sur port 993 + login en clair"
    echo "  5) Thunderbird: IMAP/IMAPS + SMTP (STARTTLS)"
  else
    echo "  3) IMAP: connexion sur port 143 et login en clair"
    echo "  4) Thunderbird: IMAP (Non chiffré) + SMTP (Non chiffré)"
  fi
  echo
}

main "$@"

