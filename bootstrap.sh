#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# server-infra bootstrap v2 (Ubuntu 24.04, first run as root)
# Идемпотентный скрипт: можно перезапускать.
# ============================================================

LOG_FILE="/root/server-infra-bootstrap.log"
SECRETS_DIR="/root/secrets"
CONFIG_FILE="${SECRETS_DIR}/server-infra.env"
ENV_LINK="./.env"

exec > >(tee -a "${LOG_FILE}") 2>&1
echo "=== Bootstrap v2 started at $(date -Is) ==="

# ---------- helpers ----------
log()  { echo "[$(date +%H:%M:%S)] $*"; }
warn() { echo "[$(date +%H:%M:%S)] WARN: $*" >&2; }
die()  { echo "[$(date +%H:%M:%S)] ERROR: $*" >&2; exit 1; }

require_root() {
  if [[ $EUID -ne 0 ]]; then
    die "Скрипт должен запускаться от root (sudo -i или sudo ./bootstrap.sh)"
  fi
}

# отказываемся работать с CRLF-файлом
check_line_endings() {
  if head -1 "$0" | grep -q $'\r'; then
    die "В файле скрипта CRLF-переводы строк. Выполните: sed -i 's/\\r$//' $0"
  fi
}

# читает переменную из уже существующего env-файла (если есть)
load_prev() {
  local key="$1"
  if [[ -f "${CONFIG_FILE}" ]]; then
    grep -E "^${key}=" "${CONFIG_FILE}" 2>/dev/null | tail -1 | cut -d= -f2- || true
  fi
}

# запрашивает значение с учётом предыдущего и дефолта
# $4 = "optional" → пустое значение разрешено
ask() {
  local var_name="$1" prompt="$2" default="${3:-}" mode="${4:-required}" prev
  prev="$(load_prev "${var_name}")"
  local effective_default="${prev:-${default}}"
  local input
  read -r -p "${prompt} [${effective_default}]: " input || true
  input="${input:-${effective_default}}"
  if [[ "${mode}" == "required" && -z "${input}" ]]; then
    die "Значение для ${var_name} не может быть пустым."
  fi
  printf -v "${var_name}" '%s' "${input}"
  export "${var_name?}"
}

# $3 = "optional" → пустое значение разрешено (для WG_PRIVATE_KEY)
ask_secret() {
  local var_name="$1" prompt="$2" mode="${3:-required}"
  local prev input
  prev="$(load_prev "${var_name}")"
  if [[ -n "${prev}" ]]; then
    read -r -s -p "${prompt} [Enter = использовать сохранённый]: " input || true
    echo
    input="${input:-${prev}}"
  else
    read -r -s -p "${prompt}: " input || true
    echo
  fi
  if [[ "${mode}" == "required" && -z "${input}" ]]; then
    die "Значение для ${var_name} обязательно."
  fi
  printf -v "${var_name}" '%s' "${input}"
  export "${var_name?}"
}

# upsert в env-файл (идемпотентно)
write_env() {
  local key="$1" value="$2"
  touch "${CONFIG_FILE}"
  chmod 600 "${CONFIG_FILE}"
  if grep -qE "^${key}=" "${CONFIG_FILE}" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${value}|" "${CONFIG_FILE}"
  else
    echo "${key}=${value}" >> "${CONFIG_FILE}"
  fi
  log "Сохранено ${key}=***"
}

is_number() { [[ "$1" =~ ^[0-9]+$ ]]; }

# ---------- 0. checks ----------
require_root
check_line_endings
command -v curl >/dev/null 2>&1 || die "Не найден curl. Установите: apt-get install -y curl"

mkdir -p "${SECRETS_DIR}"
chmod 700 "${SECRETS_DIR}"

if [[ -f "${CONFIG_FILE}" ]]; then
  echo "Обнаружен существующий конфиг: ${CONFIG_FILE}"
  read -r -p "Использовать сохранённые значения? [Y/n]: " reuse
  reuse="${reuse:-Y}"
  if [[ "${reuse}" =~ ^[Yy] ]]; then
    # shellcheck source=/dev/null
    source "${CONFIG_FILE}"
    log "Загружены значения из ${CONFIG_FILE}"
  else
    log "Перезапись конфигурации."
    rm -f "${CONFIG_FILE}"
  fi
fi

# ---------- 1. сбор переменных ----------
log "Шаг 1/5: Сбор переменных."

ask ADMIN_USER "Имя административного пользователя" "anton"
ask SSH_PORT   "Порт SSH" "22"
is_number "${SSH_PORT}" || die "SSH_PORT должен быть числом."
ask WG_PORT    "UDP-порт WireGuard" "51820"
is_number "${WG_PORT}" || die "WG_PORT должен быть числом."
ask WG_NETWORK "Подсеть WireGuard (CIDR)" "10.8.0.0/24"
ask SERVER_IP  "Публичный IP сервера (пусто = автоопределение)" "" "optional"

if [[ -z "${SERVER_IP}" ]]; then
  SERVER_IP="$(curl -4 -fsS https://ifconfig.me 2>/dev/null || true)"
  [[ -n "${SERVER_IP}" ]] || die "Не удалось определить публичный IP. Укажите SERVER_IP вручную."
  log "Автоопределён SERVER_IP=${SERVER_IP}"
fi

# WG_PRIVATE_KEY — необязательный: пусто = сгенерировать позже
ask_secret WG_PRIVATE_KEY "Приватный ключ WireGuard (пусто = сгенерировать)" optional

# ---------- 2. сохранение конфига ----------
log "Шаг 2/5: Сохранение конфигурации."
write_env ADMIN_USER "${ADMIN_USER}"
write_env SSH_PORT   "${SSH_PORT}"
write_env WG_PORT    "${WG_PORT}"
write_env WG_NETWORK "${WG_NETWORK}"
write_env SERVER_IP  "${SERVER_IP}"

if [[ -L "${ENV_LINK}" || -f "${ENV_LINK}" ]]; then
  log "${ENV_LINK} уже существует — оставляем как есть."
else
  ln -s "${CONFIG_FILE}" "${ENV_LINK}"
  log "Создан симлинк ${ENV_LINK} -> ${CONFIG_FILE}"
fi

# ---------- 3. SSH hardening (пароль для ADMIN_USER, root по SSH запрещён) ----------
log "Шаг 3/5: Базовый hardening (обновления, UFW, fail2ban, SSH)."

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y

# UFW
command -v ufw >/dev/null 2>&1 || apt-get install -y ufw
ufw --force default deny incoming
ufw --force default allow outgoing
ufw allow "${SSH_PORT}/tcp" comment 'SSH'
ufw allow "${WG_PORT}/udp" comment 'WireGuard'
ufw --force enable
log "UFW: deny incoming, allow ${SSH_PORT}/tcp и ${WG_PORT}/udp."

# fail2ban
dpkg -s fail2ban >/dev/null 2>&1 || apt-get install -y fail2ban
systemctl enable --now fail2ban
log "fail2ban установлен и запущен."

# Пользователь-администратор (создаётся, если его нет)
if id "${ADMIN_USER}" >/dev/null 2>&1; then
  log "Пользователь ${ADMIN_USER} уже существует."
else
  useradd -m -s /bin/bash -G sudo "${ADMIN_USER}"
  log "Создан ${ADMIN_USER} (в группе sudo)."
fi

# sudo без пароля НЕ настраиваем — пусть спрашивает (безопаснее)
# но гарантируем, что anton в sudo
if ! id -nG "${ADMIN_USER}" | tr ' ' '\n' | grep -qx sudo; then
  usermod -aG sudo "${ADMIN_USER}"
  log "Добавлен ${ADMIN_USER} в группу sudo."
fi

# Проверяем, что пароль установлен (это единственный способ входа)
if passwd -S "${ADMIN_USER}" | awk '{print $2}' | grep -qE '^(L|NP)$'; then
  warn "У ${ADMIN_USER} нет действующего пароля (заблокирован или не задан)."
  warn "Задайте сейчас: passwd ${ADMIN_USER}"
  warn "После этого перезапустите bootstrap или просто закройте/откройте сессию."
fi

# SSH hardening: пароль для anton, root по SSH запрещён
SSHD_CONFIG="/etc/ssh/sshd_config.d/99-server-infra.conf"
cat > "${SSHD_CONFIG}" <<EOF
Port ${SSH_PORT}
PermitRootLogin no
PasswordAuthentication yes
KbdInteractiveAuthentication no
PubkeyAuthentication yes
EOF

if sshd -t; then
  systemctl reload ssh
  log "SSH: порт ${SSH_PORT}, PermitRootLogin=no, PasswordAuthentication=yes."
else
  warn "sshd -t не прошёл. Файл ${SSHD_CONFIG} создан, рестарт НЕ выполнен."
fi

# ---------- 4. Docker ----------
log "Шаг 4/5: Установка Docker."
if command -v docker >/dev/null 2>&1; then
  log "Docker уже установлен — пропускаем."
else
  apt-get install -y ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
  fi
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
    ${OS_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
  log "Docker установлен."
fi

# ---------- 5. WireGuard ----------
log "Шаг 5/5: Установка и настройка WireGuard."
dpkg -s wireguard >/dev/null 2>&1 || apt-get install -y wireguard

WG_DIR="/etc/wireguard"
mkdir -p "${WG_DIR}"
chmod 700 "${WG_DIR}"

WG_PRIV_FILE="${WG_DIR}/privatekey"
WG_PUB_FILE="${WG_DIR}/publickey"

if [[ ! -f "${WG_PRIV_FILE}" ]]; then
  if [[ -n "${WG_PRIVATE_KEY:-}" ]]; then
    echo "${WG_PRIVATE_KEY}" > "${WG_PRIV_FILE}"
  else
    wg genkey > "${WG_PRIV_FILE}"
  fi
  chmod 600 "${WG_PRIV_FILE}"
  wg pubkey < "${WG_PRIV_FILE}" > "${WG_PUB_FILE}"
  log "Ключи WireGuard готовы."
else
  log "Приватный ключ WireGuard уже существует."
fi

WG_PRIVATE_KEY="$(cat "${WG_PRIV_FILE}")"
write_env WG_PRIVATE_KEY "${WG_PRIVATE_KEY}"

WG_CONF="${WG_DIR}/wg0.conf"
if [[ ! -f "${WG_CONF}" ]]; then
  WG_SERVER_IP="${WG_NETWORK%.*}.1"
  cat > "${WG_CONF}" <<EOF
[Interface]
Address = ${WG_SERVER_IP}/24
ListenPort = ${WG_PORT}
PrivateKey = ${WG_PRIVATE_KEY}
EOF
  chmod 600 "${WG_CONF}"
  log "Создан ${WG_CONF} (Address=${WG_SERVER_IP}/24, ListenPort=${WG_PORT})."
else
  log "${WG_CONF} уже существует — не перезаписываем."
fi

systemctl enable --now wg-quick@wg0 || warn "Не удалось включить wg-quick@wg0 (проверьте конфиг)."

echo "=== Bootstrap v2 completed at $(date -Is) ==="
echo "Конфигурация: ${CONFIG_FILE}"
echo "Симлинк: ${ENV_LINK}"
echo "Лог: ${LOG_FILE}"

