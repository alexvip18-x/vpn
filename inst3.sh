#!/bin/bash
# L2TP/IPsec VPN installer for Ubuntu 22.04 (Jammy)
# Usage:
#   ./inst22.sh user1 pass123
#   ./inst22.sh          # спросит логин/пароль

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# ---------- CONFIG ----------
VPN_LOCAL_IP="10.10.10.1"
VPN_POOL_START="10.10.10.10"
VPN_POOL_END="10.10.10.50"
VPN_SUBNET="10.10.10.0/24"
VPN_DNS1="8.8.8.8"
VPN_DNS2="1.1.1.1"
PSK="MyStrongPSK123"

detect_wan_if() {
  ip -4 route show default | awk '/default/ {print $5; exit}' || echo eth0
}
WAN_IF="$(detect_wan_if)"

# ---------- USER/PASS ----------
if [[ "${1:-}" != "" && "${1:0:1}" != "-" ]]; then
  VPN_USER="$1"
else
  read -rp "Введите имя пользователя для VPN: " VPN_USER
fi

if [[ "${2:-}" != "" && "${2:0:1}" != "-" ]]; then
  VPN_PASS="$2"
else
  read -rsp "Введите пароль для $VPN_USER: " VPN_PASS; echo
fi

echo "[*] Установка пакетов..."
apt-get update -y
apt-get install -y strongswan xl2tpd ppp iptables-persistent curl

echo "[*] Проверка модулей ядра..."
if ! modinfo pppol2tp >/dev/null 2>&1 || ! modinfo l2tp_ppp >/dev/null 2>&1; then
  echo "❌ В ядре нет pppol2tp/l2tp_ppp. Ты точно на Ubuntu 22.04 LTS с ядром 5.15?"
  exit 1
fi

modprobe pppol2tp
modprobe l2tp_ppp
grep -q '^pppol2tp$' /etc/modules || echo pppol2tp >> /etc/modules
grep -q '^l2tp_ppp$' /etc/modules || echo l2tp_ppp >> /etc/modules

echo "[*] Включаем IP forwarding..."
sysctl -w net.ipv4.ip_forward=1 >/dev/null
grep -q '^net\.ipv4\.ip_forward=1' /etc/sysctl.conf || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf

# ---------- IPsec ----------
echo "[*] Настраиваем IPsec..."
cat >/etc/ipsec.conf <<EOF
config setup
    uniqueids=no

conn L2TP-PSK
    keyexchange=ikev1
    type=transport
    authby=psk
    ike=aes256-sha1-modp1024,aes256-sha1-modp2048,aes128-sha1-modp1024,aes128-sha1-modp2048,3des-sha1-modp1024!
    esp=aes256-sha1,aes128-sha1,3des-sha1!
    left=%defaultroute
    leftprotoport=17/1701
    right=%any
    rightprotoport=17/%any
    forceencaps=yes
    auto=add
EOF

cat >/etc/ipsec.secrets <<EOF
: PSK "$PSK"
EOF
chmod 600 /etc/ipsec.secrets

# ---------- xl2tpd ----------
echo "[*] Настраиваем xl2tpd..."
cat >/etc/xl2tpd/xl2tpd.conf <<EOF
[global]
port = 1701
listen-addr = 0.0.0.0

[lns default]
ip range = ${VPN_POOL_START}-${VPN_POOL_END}
local ip = ${VPN_LOCAL_IP}
require chap = yes
refuse pap = yes
require authentication = yes
name = L2TP-Server
ppp debug = yes
pppoptfile = /etc/ppp/options.xl2tpd
length bit = yes
EOF

# ---------- PPP ----------
echo "[*] Настраиваем PPP..."
cat >/etc/ppp/options.xl2tpd <<EOF
require-mschap-v2
refuse-pap
refuse-chap
refuse-mschap
noccp
mtu 1400
mru 1400
ms-dns ${VPN_DNS1}
ms-dns ${VPN_DNS2}
auth
lock
proxyarp
connect-delay 5000
EOF

# ---------- User ----------
echo "[*] Создаём пользователя..."
cat >/etc/ppp/chap-secrets <<EOF
$VPN_USER  l2tpd  $VPN_PASS  *
EOF
chmod 600 /etc/ppp/chap-secrets

# ---------- NAT ----------
echo "[*] Включаем NAT на $WAN_IF..."
iptables -t nat -D POSTROUTING -s "$VPN_SUBNET" -o "$WAN_IF" -j MASQUERADE 2>/dev/null || true
iptables -t nat -A POSTROUTING -s "$VPN_SUBNET" -o "$WAN_IF" -j MASQUERADE
netfilter-persistent save

# ---------- Restart ----------
echo "[*] Перезапуск сервисов..."
if systemctl list-unit-files | grep -q '^strongswan-starter\.service'; then
  STRONGSWAN=strongswan-starter
else
  STRONGSWAN=strongswan
fi

systemctl restart $STRONGSWAN
systemctl restart xl2tpd

SERVER_IP=$(curl -s ifconfig.me || echo "YOUR_SERVER_IP")

cat <<EOF
=========================================
✅ L2TP/IPsec VPN установлен (Ubuntu 22.04)
Сервер IP:        $SERVER_IP
WAN интерфейс:    $WAN_IF
L2TP шлюз:        $VPN_LOCAL_IP
Пул клиентов:     ${VPN_POOL_START}-${VPN_POOL_END}
Пользователь:     $VPN_USER
Пароль:           $VPN_PASS
PSK (общий ключ): $PSK
Порты: UDP/500, UDP/4500, UDP/1701
=========================================
Windows/macOS/iOS/Android:
- Тип VPN: L2TP/IPsec с PSK
- Сервер: $SERVER_IP
- PSK: $PSK
- Логин/пароль: $VPN_USER / $VPN_PASS
- Аутентификация: MS-CHAPv2
======================================
██████╗░██╗░░██╗███╗░░██╗  ░██████╗░█████╗░░██████╗██╗  ██╗░░██╗██╗░░░██╗██╗
██╔══██╗██║░██╔╝████╗░██║  ██╔════╝██╔══██╗██╔════╝██║  ██║░░██║██║░░░██║██║
██████╔╝█████═╝░██╔██╗██║  ╚█████╗░██║░░██║╚█████╗░██║  ███████║██║░░░██║██║
██╔══██╗██╔═██╗░██║╚████║  ░╚═══██╗██║░░██║░╚═══██╗██║  ██╔══██║██║░░░██║██║
██║░░██║██║░╚██╗██║░╚███║  ██████╔╝╚█████╔╝██████╔╝██║  ██║░░██║╚██████╔╝██║
╚═╝░░╚═╝╚═╝░░╚═╝╚═╝░░╚══╝  ╚═════╝░░╚════╝░╚═════╝░╚═╝  ╚═╝░░╚═╝░╚═════╝░╚═╝
EOF