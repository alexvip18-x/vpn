#!/bin/bash
# L2TP/IPsec (PSK) installer for Ubuntu/Debian
# Usage:
#   ./install-l2tp-ipsec.sh USER PASS
#   ./install-l2tp-ipsec.sh        # will prompt

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# ---------- CONFIG ----------
VPN_LOCAL_IP="10.10.10.1"
VPN_POOL_START="10.10.10.10"
VPN_POOL_END="10.10.10.50"
VPN_DNS1="8.8.8.8"
VPN_DNS2="1.1.1.1"
PSK="${PSK:-MyStrongPSK123}"     # можно задать через env PSK=...
AUTO_REBOOT="${AUTO_REBOOT:-0}"  # 1 = перезагрузить автоматически, если нужно
# ----------------------------

# derive /24 subnet from VPN_LOCAL_IP
VPN_SUBNET="$(echo "$VPN_LOCAL_IP" | awk -F. '{printf "%s.%s.%s.0/24",$1,$2,$3}')"

detect_wan_if() {
  ip -4 route show default 2>/dev/null | awk '/default/ {print $5; exit}' || true
}
WAN_IF="${WAN_IF:-$(detect_wan_if)}"; WAN_IF="${WAN_IF:-eth0}"

# --- USER/PASS ---
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

echo "[*] Пакеты..."
apt-get update -y
apt-get install -y strongswan xl2tpd ppp iptables-persistent curl ca-certificates

# удалить возможные конфликты (редко, но бывает)
dpkg -l | awk '/libreswan|openswan/ {print $2}' | xargs -r apt-get -y purge

# ---------- ensure kernel modules present ----------
need_modules() {
  modinfo pppol2tp >/dev/null 2>&1 && modinfo l2tp_ppp >/dev/null 2>&1
}
if ! need_modules; then
  echo "[*] Пробуем установить linux-modules-extra-$(uname -r) ..."
  apt-get install -y "linux-modules-extra-$(uname -r)" || true
fi
if ! need_modules; then
  echo "[!] Для текущего ядра нет extra-модулей. Ставлю meta-ядро linux-generic (содержит pppol2tp/l2tp_ppp)."
  apt-get install -y linux-generic || true
  echo
  echo "⚠️ Нужна перезагрузка, чтобы загрузиться в новое ядро с модулями."
  echo "   Перезагрузи сервер, затем снова запусти этот же скрипт."
  if [[ "$AUTO_REBOOT" == "1" ]]; then
    echo "   Перезагружаю автоматически через 5 секунд..."
    sleep 5
    reboot
  fi
  exit 100
fi

echo "[*] Загружаю модули ядра..."
modprobe pppol2tp || true
modprobe l2tp_ppp || true
grep -q '^pppol2tp$' /etc/modules 2>/dev/null || echo pppol2tp >> /etc/modules
grep -q '^l2tp_ppp$' /etc/modules 2>/dev/null || echo l2tp_ppp >> /etc/modules

echo "[*] Включаем IP forwarding и sane sysctl..."
sysctl -w net.ipv4.ip_forward=1 >/dev/null
grep -q '^net\.ipv4\.ip_forward=1' /etc/sysctl.conf || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
sysctl -w net.ipv4.conf.all.send_redirects=0 >/dev/null || true
sysctl -w net.ipv4.conf.default.send_redirects=0 >/dev/null || true
sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null || true
sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null || true

echo "[*] strongSwan (IPsec) конфиг..."
cat >/etc/ipsec.conf <<'EOF'
config setup
    uniqueids=no
EOF

cat >>/etc/ipsec.conf <<EOF
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

install -m 600 /dev/null /etc/ipsec.secrets
echo ": PSK \"$PSK\"" >/etc/ipsec.secrets
chmod 600 /etc/ipsec.secrets

echo "[*] xl2tpd конфиг..."
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

echo "[*] PPP options..."
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

echo "[*] Пользователь..."
install -m 600 /dev/null /etc/ppp/chap-secrets
echo "${VPN_USER}  l2tpd  ${VPN_PASS}  *" >/etc/ppp/chap-secrets
chmod 600 /etc/ppp/chap-secrets

echo "[*] NAT на ${WAN_IF} для ${VPN_SUBNET} ..."
iptables -t nat -D POSTROUTING -s "${VPN_SUBNET}" -o "${WAN_IF}" -j MASQUERADE 2>/dev/null || true
iptables -t nat -A POSTROUTING -s "${VPN_SUBNET}" -o "${WAN_IF}" -j MASQUERADE
netfilter-persistent save

echo "[*] Рестарт сервисов..."
if systemctl list-unit-files | grep -q '^strongswan-starter\.service'; then
  STRONGSWAN_SERVICE=strongswan-starter
else
  STRONGSWAN_SERVICE=strongswan
fi

systemctl restart "${STRONGSWAN_SERVICE}"
# xl2tpd — SysV, enable может ругаться; нам важно, чтобы он стартовал:
systemctl restart xl2tpd || {
  echo "❌ xl2tpd не стартовал. Логи:"
  journalctl -xeu xl2tpd --no-pager | tail -n 150
  exit 1
}

echo "[*] Проверка портов (UDP 500/4500/1701)..."
ss -lunp | grep -E '(:500|:4500|:1701)' || true

PUB_IP="$(curl -sS --max-time 3 https://ifconfig.me || echo "YOUR_SERVER_IP")"

cat <<EOF

======================================
✅ Готово: L2TP/IPsec VPN установлен
Публичный IP:          ${PUB_IP}
WAN-интерфейс:         ${WAN_IF}
L2TP шлюз:             ${VPN_LOCAL_IP}
Пул клиентов:          ${VPN_POOL_START}-${VPN_POOL_END} (${VPN_SUBNET})
Пользователь:          ${VPN_USER}
Пароль:                ${VPN_PASS}
PSK (общий ключ):      ${PSK}
Порты: UDP/500, UDP/4500, UDP/1701

Windows/macOS/iOS/Android:
- Тип VPN: L2TP/IPsec (PSK)
- Сервер: ${PUB_IP}
- PSK: ${PSK}
- Логин/пароль: ${VPN_USER}/${VPN_PASS}
- Аутентификация: MS-CHAP v2
======================================
██████╗░██╗░░██╗███╗░░██╗  ░██████╗░█████╗░░██████╗██╗  ██╗░░██╗██╗░░░██╗██╗
██╔══██╗██║░██╔╝████╗░██║  ██╔════╝██╔══██╗██╔════╝██║  ██║░░██║██║░░░██║██║
██████╔╝█████═╝░██╔██╗██║  ╚█████╗░██║░░██║╚█████╗░██║  ███████║██║░░░██║██║
██╔══██╗██╔═██╗░██║╚████║  ░╚═══██╗██║░░██║░╚═══██╗██║  ██╔══██║██║░░░██║██║
██║░░██║██║░╚██╗██║░╚███║  ██████╔╝╚█████╔╝██████╔╝██║  ██║░░██║╚██████╔╝██║
╚═╝░░╚═╝╚═╝░░╚═╝╚═╝░░╚══╝  ╚═════╝░░╚════╝░╚═════╝░╚═╝  ╚═╝░░╚═╝░╚═════╝░╚═╝
EOF