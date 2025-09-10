#!/bin/bash
# inst5.sh — L2TP/IPsec (PSK) installer (strongSwan + xl2tpd + pppd)
# Генерит PSK и 4 пользователей: user1..user4 с уникальными паролями.
# Usage: bash inst5.sh

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# ---------- helpers ----------
rand_alnum () {
  # 20 символов A-Za-z0-9 (без спецзнаков)
  tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20
}

detect_wan_if(){ ip -4 route show default 2>/dev/null | awk '/default/ {print $5; exit}'; }

# ---------- network/profile ----------
VPN_LOCAL_IP="10.10.10.1"
VPN_POOL_START="10.10.10.10"
VPN_POOL_END="10.10.10.50"
VPN_SUBNET="$(awk -F. '{printf "%s.%s.%s.0/24",$1,$2,$3}' <<<"$VPN_LOCAL_IP")"
VPN_DNS1="${VPN_DNS1:-8.8.8.8}"
VPN_DNS2="${VPN_DNS2:-1.1.1.1}"
WAN_IF="${WAN_IF:-$(detect_wan_if)}"; WAN_IF="${WAN_IF:-eth0}"

# ---------- creds (PSK + 4 users) ----------
PSK="$(rand_alnum)"
U1="user1"; P1="$(rand_alnum)"
U2="user2"; P2="$(rand_alnum)"
U3="user3"; P3="$(rand_alnum)"
U4="user4"; P4="$(rand_alnum)"

# ---------- install ----------
echo "[*] Установка пакетов..."
apt-get update -y
apt-get install -y strongswan xl2tpd ppp iptables-persistent curl ca-certificates

cat << "EOF"

▗▖    ▗▄▖ ▗▄▄▄  ▗▖  ▗▖ ▗▄▖     ▗▖ ▗▖▗▖ ▗▖▗▄▄▄▖     ▗▄▄▖    ▗▖  ▗▖▗▄▄▄▖▗▖  ▗▖
▐▌   ▐▌ ▐▌▐▌  █ ▐▛▚▖▐▌▐▌ ▐▌    ▐▌ ▐▌▐▌ ▐▌  █      ▐▌       ▐▛▚▖▐▌  █  ▐▛▚▞▜▌
▐▌   ▐▛▀▜▌▐▌  █ ▐▌ ▝▜▌▐▌ ▐▌    ▐▛▀▜▌▐▌ ▐▌  █      ▐▌       ▐▌ ▝▜▌  █  ▐▌  ▐▌
▐▙▄▄▖▐▌ ▐▌▐▙▄▄▀ ▐▌  ▐▌▝▚▄▞▘    ▐▌ ▐▌▝▚▄▞▘▗▄█▄▖    ▝▚▄▄▖    ▐▌  ▐▌▗▄█▄▖▐▌  ▐▌
 
EOF


# ---------- kernel modules (мягкая попытка) ----------
echo "[*] Проверка L2TP модулей ядра..."
modprobe l2tp_ppp 2>/dev/null || true
modprobe l2tp_netlink 2>/dev/null || true

# ---------- sysctl ----------
echo "[*] Включаю IPv4 forwarding..."
sysctl -w net.ipv4.ip_forward=1 >/dev/null
grep -q '^net\.ipv4\.ip_forward=1' /etc/sysctl.conf || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf

# ---------- backups ----------
ts="$(date +%Y%m%d-%H%M%S)"
for f in /etc/ipsec.conf /etc/ipsec.secrets /etc/xl2tpd/xl2tpd.conf /etc/ppp/options.xl2tpd /etc/ppp/chap-secrets; do
  [[ -f "$f" ]] && cp -a "$f" "${f}.bak-${ts}" || true
done

# ---------- strongSwan ----------
echo "[*] Пишу /etc/ipsec.conf ..."
cat >/etc/ipsec.conf <<'EOF'
config setup
    uniqueids=no

conn L2TP-PSK
    keyexchange=ikev1
    type=transport
    authby=psk
    ike=aes256-sha1-modp1024,aes256-sha1-modp2048,aes128-sha1-modp1024,aes128-sha1-modp2048,3des-sha1-modp1024,3des-sha1-modp2048!
    esp=aes256-sha1,aes128-sha1,3des-sha1!
    ikelifetime=8h
    keylife=1h
    rekey=yes
    left=%defaultroute
    leftprotoport=17/1701
    right=%any
    rightprotoport=17/%any
    auto=add
EOF

echo "[*] Пишу /etc/ipsec.secrets ..."
install -m 600 /dev/null /etc/ipsec.secrets
echo ": PSK \"$PSK\"" >/etc/ipsec.secrets

# ---------- xl2tpd ----------
echo "[*] Пишу /etc/xl2tpd/xl2tpd.conf ..."
cat >/etc/xl2tpd/xl2tpd.conf <<EOF
[global]
port = 1701
debug tunnel = yes
debug avp = yes
debug network = yes

[lns default]
ip range = ${VPN_POOL_START}-${VPN_POOL_END}
local ip = ${VPN_LOCAL_IP}
refuse pap = yes
require authentication = yes
name = l2tpd
pppoptfile = /etc/ppp/options.xl2tpd
length bit = yes
EOF

# ---------- PPP ----------
echo "[*] Пишу /etc/ppp/options.xl2tpd ..."
cat >/etc/ppp/options.xl2tpd <<EOF
name l2tpd
auth
require-mschap-v2
refuse-mschap
# НЕ ставить refuse-chap!

# Без компрессии — меньше глюков
noccp

# MTU/MRU для L2TP поверх IPsec
mtu 1400
mru 1400

# DNS клиентам
ms-dns ${VPN_DNS1}
ms-dns ${VPN_DNS2}

# Логи pppd
debug
logfile /var/log/pppd.log
EOF

echo "[*] Пишу /etc/ppp/chap-secrets (4 пользователя)..."
install -m 600 /dev/null /etc/ppp/chap-secrets
cat >/etc/ppp/chap-secrets <<EOF
${U1}  l2tpd  ${P1}  *
${U2}  l2tpd  ${P2}  *
${U3}  l2tpd  ${P3}  *
${U4}  l2tpd  ${P4}  *
EOF
chmod 600 /etc/ppp/chap-secrets

# ---------- NAT ----------
echo "[*] Включаю NAT для ${VPN_SUBNET} через ${WAN_IF} ..."
iptables -t nat -C POSTROUTING -s "${VPN_SUBNET}" -o "${WAN_IF}" -j MASQUERADE 2>/dev/null || \
iptables -t nat -A POSTROUTING -s "${VPN_SUBNET}" -o "${WAN_IF}" -j MASQUERADE
command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save || true

# ---------- services ----------
echo "[*] Перезапуск сервисов..."
systemctl enable xl2tpd >/dev/null 2>&1 || true
if systemctl list-unit-files | grep -q '^strongswan-starter\.service'; then
  systemctl enable strongswan-starter >/dev/null 2>&1 || true
  systemctl restart strongswan-starter
else
  systemctl enable strongswan >/dev/null 2>&1 || true
  systemctl restart strongswan
fi
systemctl restart xl2tpd

# ---------- save creds to file ----------
PUB_IP="$(curl -4 -fsS --max-time 5 https://ifconfig.me || curl -4 -fsS --max-time 5 ifconfig.co || echo 'YOUR_SERVER_IP')"
CREDFILE="/root/l2tp_credentials_${ts}.txt"
cat >"$CREDFILE" <<EOF
Public IP: ${PUB_IP}
PSK: ${PSK}
Users:
  ${U1} / ${P1}
  ${U2} / ${P2}
  ${U3} / ${P3}
  ${U4} / ${P4}
EOF
chmod 600 "$CREDFILE"

# ---------- summary ----------
cat <<EOF
██████╗░░█████╗░███████╗██╗░░██╗░█████╗░██╗░░░░░██╗
██╔══██╗██╔══██╗██╔════╝██║░░██║██╔══██╗██║░░░░░██║
██████╔╝██║░░██║█████╗░░███████║███████║██║░░░░░██║
██╔═══╝░██║░░██║██╔══╝░░██╔══██║██╔══██║██║░░░░░██║
██║░░░░░╚█████╔╝███████╗██║░░██║██║░░██║███████╗██║
╚═╝░░░░░░╚════╝░╚══════╝╚═╝░░╚═╝╚═╝░░╚═╝╚══════╝╚═╝
===================================================
✅ L2TP/IPsec VPN поднят

Сервер (публ. IP): ${PUB_IP}
WAN интерфейс:     ${WAN_IF}
L2TP шлюз:         ${VPN_LOCAL_IP}
Пул клиентов:      ${VPN_POOL_START}-${VPN_POOL_END} (${VPN_SUBNET})

PSK: ${PSK}

Пользователи:
  ${U1} / ${P1}
  ${U2} / ${P2}
  ${U3} / ${P3}
  ${U4} / ${P4}

Логи:
  journalctl -fu strongswan-starter
  journalctl -fu xl2tpd
  tail -f /var/log/pppd.log

Клиенты (Windows/macOS/iOS/Android):
- L2TP/IPsec (PSK)
- Сервер: ${PUB_IP}
- PSK:    ${PSK}
- Login/Pass: как выше
- Auth:   MS-CHAPv2

Файл c доступами: ${CREDFILE}
(проверь и спрячь)
===================================================================================
███████████████████████████████████████████████████████████████████████████████████
█─█─█▄─▄▄─█─▄─▄─█░▄▄░▄█▄─▀█▄─▄█▄─▄▄─█▄─▄▄▀███─▄▄▄▄█─▄▄─█─▄▄▄▄█▄─▄███─█─█▄─██─▄█▄─▄█
█─▄─██─▄█▀███─████▀▄█▀██─█▄▀─███─▄█▀██─▄─▄███▄▄▄▄─█─██─█▄▄▄▄─██─████─▄─██─██─███─██
▀▄▀▄▀▄▄▄▄▄▀▀▄▄▄▀▀▄▄▄▄▄▀▄▄▄▀▀▄▄▀▄▄▄▄▄▀▄▄▀▄▄▀▀▀▄▄▄▄▄▀▄▄▄▄▀▄▄▄▄▄▀▄▄▄▀▀▀▄▀▄▀▀▄▄▄▄▀▀▄▄▄▀
EOF
