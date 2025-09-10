#!/bin/bash
# L2TP (без IPsec) auto install script for Debian/Ubuntu
# Можно задать имя и пароль пользователя при запуске:
#   ./install-l2tp.sh username password

set -e

# --- Настройки по умолчанию ---
VPN_LOCAL_IP="10.10.10.1"
VPN_POOL="10.10.10.10-10.10.10.50"
VPN_DNS1="8.8.8.8"
VPN_DNS2="1.1.1.1"
WAN_IF="eth0"   # замени на свой внешний интерфейс

# --- Пользователь/пароль ---
if [ -n "$1" ]; then
    VPN_USER="$1"
else
    read -rp "Введите имя пользователя для VPN: " VPN_USER
fi

if [ -n "$2" ]; then
    VPN_PASS="$2"
else
    read -rsp "Введите пароль для $VPN_USER: " VPN_PASS
    echo
fi

echo "[*] Установка пакетов..."
apt update
apt install -y xl2tpd ppp iptables-persistent curl

echo "[*] Включаем IP forward..."
sysctl -w net.ipv4.ip_forward=1
grep -q "net.ipv4.ip_forward" /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

echo "[*] Настройка /etc/xl2tpd/xl2tpd.conf..."
cat > /etc/xl2tpd/xl2tpd.conf <<EOF
[global]
listen-addr = 0.0.0.0

[lns default]
ip range = $VPN_POOL
local ip = $VPN_LOCAL_IP
require chap = yes
refuse pap = yes
ppp debug = yes
pppoptfile = /etc/ppp/options.xl2tpd
length bit = yes
EOF

echo "[*] Настройка /etc/ppp/options.xl2tpd..."
cat > /etc/ppp/options.xl2tpd <<EOF
ipcp-accept-local
ipcp-accept-remote
ms-dns $VPN_DNS1
ms-dns $VPN_DNS2
auth
mtu 1410
mru 1410
noccp
nodefaultroute
lock
proxyarp
connect-delay 5000
EOF

echo "[*] Создание пользователя..."
cat > /etc/ppp/chap-secrets <<EOF
$VPN_USER  l2tpd  $VPN_PASS  *
EOF
chmod 600 /etc/ppp/chap-secrets

echo "[*] Настройка NAT через iptables..."
iptables -t nat -A POSTROUTING -s ${VPN_POOL%-*}/24 -o $WAN_IF -j MASQUERADE

# Сохраняем правила
netfilter-persistent save

echo "[*] Перезапуск xl2tpd..."
systemctl enable xl2tpd
systemctl restart xl2tpd

SERVER_IP=$(curl -s ifconfig.me || echo "YOUR_SERVER_IP")

echo "======================================"
echo "✅ L2TP сервер без IPsec установлен"
echo " Сервер IP: $SERVER_IP"
echo " Внутренний шлюз VPN: $VPN_LOCAL_IP"
echo " Диапазон клиентов: $VPN_POOL"
echo " Пользователь: $VPN_USER"
echo " Пароль: $VPN_PASS"
echo "======================================"
