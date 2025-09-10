#!/bin/bash
# Установка L2TP/IPsec (PSK) на Debian/Ubuntu 20.04/22.04/24.04
# Использование:
#   ./install-l2tp-ipsec.sh user pass
#   ./install-l2tp-ipsec.sh    # спросит логин/пароль

set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

# ---- НАСТРОЙКИ ----
VPN_LOCAL_IP="10.10.10.1"
VPN_POOL_START="10.10.10.10"
VPN_POOL_END="10.10.10.50"
VPN_SUBNET="10.10.10.0/24"   # для NAT
VPN_DNS1="8.8.8.8"
VPN_DNS2="1.1.1.1"
PSK="MyStrongPSK123"

# Автоопределение внешнего интерфейса, если он не eth0
detect_wan_if() {
  local dev
  dev=$(ip -4 route show default 2>/dev/null | awk '/default/ {print $5; exit}')
  if [[ -n "${dev:-}" ]]; then
    echo "$dev"
  else
    echo "eth0"
  fi
}
WAN_IF="$(detect_wan_if)"

# ---- ПОЛЬЗОВАТЕЛЬ/ПАРОЛЬ ----
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

# Дотянуть модули ядра (для l2tp_ppp/pppol2tp)
echo "[*] Проверка и установка модулей ядра (linux-modules-extra-$(uname -r))..."
if ! ls /lib/modules/$(uname -r)/kernel/drivers/net/l2tp/ >/dev/null 2>&1 || \
   ! ls /lib/modules/$(uname -r)/kernel/net/l2tp/ >/dev/null 2>&1; then
  apt-get install -y "linux-modules-extra-$(uname -r)" || true
fi

echo "[*] Включаем IP forwarding..."
sysctl -w net.ipv4.ip_forward=1 >/dev/null
grep -q '^net\.ipv4\.ip_forward=1' /etc/sysctl.conf || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf

# Жёстко отключим отправку редиректов на внешнем интерфейсе и rp_filter (обычно полезно)
sysctl -w net.ipv4.conf.all.send_redirects=0 >/dev/null || true
sysctl -w net.ipv4.conf.default.send_redirects=0 >/dev/null || true
sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null || true
sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null || true

echo "[*] Загружаем модули l2tp_ppp и pppol2tp..."
modprobe l2tp_ppp || true
modprobe pppol2tp || true

# Добавим в автозагрузку, если их нет
grep -q '^l2tp_ppp$' /etc/modules 2>/dev/null || echo 'l2tp_ppp' >> /etc/modules
grep -q '^pppol2tp$' /etc/modules 2>/dev/null || echo 'pppol2tp' >> /etc/modules

# Проверка, что ядро поддерживает нужные модули
if ! modinfo l2tp_ppp >/dev/null 2>&1 || ! modinfo pppol2tp >/dev/null 2>&1; then
  echo "❌ В ядре отсутствуют модули l2tp_ppp/pppol2tp для $(uname -r)."
  echo "   Попробуй установить другой/полный ядро: apt-get install -y linux-image-generic linux-modules-extra-$(uname -r)"
  echo "   Или перезагрузись после установки модулей. Без этих модулей Windows/macOS клиенты не поднимутся."
  exit 1
fi

echo "[*] Настраиваем IPsec (strongSwan)..."
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

echo "[*] Настраиваем PPP (только MS-CHAPv2, MTU/MRU=1400)..."
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

echo "[*] Создаём пользователя..."
cat >/etc/ppp/chap-secrets <<EOF
$VPN_USER  l2tpd  $VPN_PASS  *
EOF
chmod 600 /etc/ppp/chap-secrets

echo "[*] Включаем NAT на ${WAN_IF} для ${VPN_SUBNET}..."
# Удалим возможное старое правило, чтобы не плодить дубли
iptables -t nat -D POSTROUTING -s ${VPN_SUBNET} -o ${WAN_IF} -j MASQUERADE 2>/dev/null || true
iptables -t nat -A POSTROUTING -s ${VPN_SUBNET} -o ${WAN_IF} -j MASQUERADE
netfilter-persistent save

echo "[*] Перезапуск сервисов..."
# Определяем корректное имя сервиса strongSwan
if systemctl list-unit-files | grep -q '^strongswan-starter\.service'; then
  STRONGSWAN_SERVICE="strongswan-starter"
else
  STRONGSWAN_SERVICE="strongswan"
fi

systemctl enable "${STRONGSWAN_SERVICE}" >/dev/null 2>&1 || true
systemctl restart "${STRONGSWAN_SERVICE}"

# xl2tpd использует SysV-скрипт под systemd — enable может ругаться, это нормально
systemctl restart xl2tpd || {
  echo "❌ xl2tpd не стартовал. Логи ниже:"
  journalctl -xeu xl2tpd --no-pager | tail -n 100
  exit 1
}

# Финальная проверка портов
echo "[*] Проверка, что порты слушаются (UDP 500/4500/1701):"
ss -lunp | grep -E '(:500|:4500|:1701)' || true

SERVER_IP=$(curl -s ifconfig.me || echo "YOUR_SERVER_IP")

cat <<EOF

======================================
✅ Готово: L2TP/IPsec VPN установлен
Сервер (публичный IP):  ${SERVER_IP}
WAN-интерфейс:          ${WAN_IF}
L2TP шлюз:              ${VPN_LOCAL_IP}
Пул клиентов:           ${VPN_POOL_START}-${VPN_POOL_END} (${VPN_SUBNET})
Пользователь:           ${VPN_USER}
Пароль:                 ${VPN_PASS}
PSK (общий ключ):       ${PSK}
Порты: UDP/500, UDP/4500, UDP/1701
======================================
██████╗░██╗░░██╗███╗░░██╗  ░██████╗░█████╗░░██████╗██╗  ██╗░░██╗██╗░░░██╗██╗
██╔══██╗██║░██╔╝████╗░██║  ██╔════╝██╔══██╗██╔════╝██║  ██║░░██║██║░░░██║██║
██████╔╝█████═╝░██╔██╗██║  ╚█████╗░██║░░██║╚█████╗░██║  ███████║██║░░░██║██║
██╔══██╗██╔═██╗░██║╚████║  ░╚═══██╗██║░░██║░╚═══██╗██║  ██╔══██║██║░░░██║██║
██║░░██║██║░╚██╗██║░╚███║  ██████╔╝╚█████╔╝██████╔╝██║  ██║░░██║╚██████╔╝██║
╚═╝░░╚═╝╚═╝░░╚═╝╚═╝░░╚══╝  ╚═════╝░░╚════╝░╚═════╝░╚═╝  ╚═╝░░╚═╝░╚═════╝░╚═╝
EOF