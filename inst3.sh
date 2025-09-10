#!/bin/bash
# L2TP/IPsec (PSK) installer — Debian/Ubuntu
# Usage:
#   ./install-l2tp-ipsec.sh USER PASS
#   ./install-l2tp-ipsec.sh      # спросит логин/пароль
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# ---------- CONFIG ----------
VPN_LOCAL_IP="10.10.10.1"
VPN_POOL_START="10.10.10.10"
VPN_POOL_END="10.10.10.50"
VPN_DNS1="${VPN_DNS1:-8.8.8.8}"
VPN_DNS2="${VPN_DNS2:-1.1.1.1}"
PSK="${PSK:-MyStrongPSK123}"

# derive /24 from VPN_LOCAL_IP
VPN_SUBNET="$(awk -F. '{printf "%s.%s.%s.0/24",$1,$2,$3}' <<<"$VPN_LOCAL_IP")"

detect_wan_if(){ ip -4 route show default 2>/dev/null | awk '/default/ {print $5; exit}'; }
WAN_IF="${WAN_IF:-$(detect_wan_if)}"; WAN_IF="${WAN_IF:-eth0}"

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

# ---------- OS INFO ----------
source /etc/os-release || true
OS_ID="${ID:-unknown}"
OS_VER="${VERSION_ID:-unknown}"
KREL="$(uname -r)"

echo "[*] Установка пакетов..."
apt-get update -y
apt-get install -y strongswan xl2tpd ppp iptables-persistent curl ca-certificates

# ---------- МОДУЛИ L2TP ----------
need_mods() {
  # Проверяем, доступны ли модули (без загрузки) — и старое, и новое имя
  modprobe -n l2tp_ppp  >/dev/null 2>&1 || modprobe -n pppol2tp >/dev/null 2>&1 || return 1
}
ensure_mods() {
  if need_mods; then return 0; fi

  # Ubuntu — дотягиваем linux-modules-extra-$(uname -r)
  if [[ "$OS_ID" == "ubuntu" ]]; then
    echo "[*] Ubuntu: ставлю linux-modules-extra-${KREL} ..."
    apt-get install -y "linux-modules-extra-${KREL}" || true
    if need_mods; then return 0; fi
    # На новых Ubuntu ядрах модули могут отсутствовать — дальше не мучаем
    echo "❌ В ядре ${KREL} нет l2tp_ppp/pppol2tp (даже после linux-modules-extra)."
    echo "   Для L2TP/IPsec возьми Ubuntu 20.04 или поставь ядро с модулями, либо используй Debian (generic ядро)."
    exit 1
  fi

  # Debian: cloud-ядро вырезано, generic — норм
  if [[ "$OS_ID" == "debian" ]]; then
    if [[ "$KREL" == *"-cloud-amd64" ]]; then
      echo "❌ Вы на Debian cloud-ядре (${KREL}) — в нём НЕТ l2tp_ppp/pppol2tp."
      echo "   Решение: установите обычное ядро и перезагрузитесь:"
      echo "     apt-get install -y linux-image-amd64 linux-headers-amd64"
      echo "     reboot"
      exit 1
    fi
    # На обычном Debian ядре модули обычно уже есть; если нет — сообщаем
    echo "❌ На Debian ядре ${KREL} модули не найдены. Установите generic ядро:"
    echo "   apt-get install -y linux-image-amd64 linux-headers-amd64 && reboot"
    exit 1
  fi

  # Прочие системы
  echo "❌ Не удалось найти l2tp_ppp/pppol2tp на ${OS_ID} ${OS_VER} (${KREL})."
  echo "   Убедитесь, что ядро собрано с этими модулями."
  exit 1
}

echo "[*] Проверяю и готовлю L2TP-модули..."
ensure_mods
# грузим, если есть
modprobe l2tp_ppp 2>/dev/null || true
modprobe pppol2tp 2>/dev/null || true

# ---------- SYSCTL ----------
echo "[*] Включаю IP forwarding и безопасные sysctl..."
sysctl -w net.ipv4.ip_forward=1 >/dev/null
grep -q '^net\.ipv4\.ip_forward=1' /etc/sysctl.conf || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
# полезные настройки для IPsec/L2TP за NAT
sysctl -w net.ipv4.conf.all.send_redirects=0 >/dev/null || true
sysctl -w net.ipv4.conf.default.send_redirects=0 >/dev/null || true
sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null || true
sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null || true

# ---------- IPsec ----------
echo "[*] Настраиваю IPsec (strongSwan)..."
cat >/etc/ipsec.conf <<EOF
config setup
    uniqueids=no

conn L2TP-PSK
    keyexchange=ikev1
    type=transport
    authby=psk
    # Windows/macOS/iOS/Android совместимые шифры
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

# ---------- xl2tpd ----------
echo "[*] Настраиваю xl2tpd..."
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
echo "[*] Настраиваю PPP..."
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

# ---------- USER ----------
echo "[*] Создаю пользователя..."
install -m 600 /dev/null /etc/ppp/chap-secrets
echo "${VPN_USER}  l2tpd  ${VPN_PASS}  *" >/etc/ppp/chap-secrets
chmod 600 /etc/ppp/chap-secrets

# ---------- NAT ----------
echo "[*] Включаю NAT на ${WAN_IF} для ${VPN_SUBNET}..."
# Удалим дубликаты, затем добавим
iptables -t nat -C POSTROUTING -s "${VPN_SUBNET}" -o "${WAN_IF}" -j MASQUERADE 2>/dev/null || \
iptables -t nat -A POSTROUTING -s "${VPN_SUBNET}" -o "${WAN_IF}" -j MASQUERADE
netfilter-persistent save

# ---------- RESTART ----------
echo "[*] Перезапуск сервисов..."
if systemctl list-unit-files | grep -q '^strongswan-starter\.service'; then
  STRONGSWAN=strongswan-starter
else
  STRONGSWAN=strongswan
fi
systemctl restart "${STRONGSWAN}"
systemctl restart xl2tpd || {
  echo "❌ xl2tpd не стартовал. Журнал:"
  journalctl -xeu xl2tpd --no-pager | tail -n 120
  exit 1
}

# ---------- INFO ----------
PUB_IP="$(curl -fsS --max-time 5 https://ifconfig.me || echo YOUR_SERVER_IP)"
echo
cat <<EOF

=========================================

✅ L2TP/IPsec VPN установлен
OS:               ${OS_ID} ${OS_VER}
Kernel:           ${KREL}
Сервер (публ. IP): ${PUB_IP}
WAN интерфейс:     ${WAN_IF}
L2TP шлюз:         ${VPN_LOCAL_IP}
Пул клиентов:      ${VPN_POOL_START}-${VPN_POOL_END} (${VPN_SUBNET})
Пользователь:      ${VPN_USER}
Пароль:            ${VPN_PASS}
PSK (общий ключ):  ${PSK}
Порты:             UDP/500, UDP/4500, UDP/1701

=========================================

Клиенты (Windows/macOS/iOS/Android):
- Тип VPN: L2TP/IPsec с PSK
- Сервер: ${PUB_IP}
- Общий ключ (PSK): ${PSK}
- Логин/пароль: ${VPN_USER}/${VPN_PASS}
- Аутентификация: MS-CHAPv2

======================================

██████╗░██╗░░██╗███╗░░██╗  ░██████╗░█████╗░░██████╗██╗  ██╗░░██╗██╗░░░██╗██╗
██╔══██╗██║░██╔╝████╗░██║  ██╔════╝██╔══██╗██╔════╝██║  ██║░░██║██║░░░██║██║
██████╔╝█████═╝░██╔██╗██║  ╚█████╗░██║░░██║╚█████╗░██║  ███████║██║░░░██║██║
██╔══██╗██╔═██╗░██║╚████║  ░╚═══██╗██║░░██║░╚═══██╗██║  ██╔══██║██║░░░██║██║
██║░░██║██║░╚██╗██║░╚███║  ██████╔╝╚█████╔╝██████╔╝██║  ██║░░██║╚██████╔╝██║
╚═╝░░╚═╝╚═╝░░╚═╝╚═╝░░╚══╝  ╚═════╝░░╚════╝░╚═════╝░╚═╝  ╚═╝░░╚═╝░╚═════╝░╚═╝
EOF