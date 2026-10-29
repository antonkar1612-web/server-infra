#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# server-infra bootstrap (Ubuntu 24.04, first run as root)
# Идемпотентный скрипт: можно перезапускать.
# ============================================================

LOG_FILE="/root/server-infra-bootstrap.log"
SECRETS_DIR="/root/secrets"
CONFIG_FILE="${SECRETS_DIR}/server-infra.env"
ENV_LINK="./.env"

exec > >(tee -a "${LOG_FILE}") 2>&1
echo "=== Bootstrap started at $(date -Is) ==="

# ---------- helpers ----------
log()  { echo "[$(date +%H:%M:%S)] $*"; }
warn() { echo "[$(date +%H:%M:%S)] WARN: $*" >&2; }
die()  { echo "[$(date +%H:%M:%S)] ERROR: $*" >&2; exit 1; }

require_root() {
  if [[ $EUID -ne 0 ]]; then
    die "Скрипт должен запускаться от root (sudo -i или sudo ./bootstrap.sh)"
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
ask() {
  local var_name="$1" prompt="$2" default="${3:-}" prev
  prev="$(load_prev "${var_name}")"
  local effective_default="${prev:-${default}}"
  local input
  read -r -p "${prompt} [${effective_default}]: " input || true
  input="${input:-${effective_default}}"
  # простая валидация: не пусто
  if [[ -z "${input}" ]]; then
    die "Значение для ${var_name} не может быть пустым."
  fi
  printf -v "${var_name}" '%s' "${input}"
  export "${var_name}"
}

ask_secret() {
  local var_name="$1" prompt="$2"
  local prev input
  prev="$(load_prev "${var_name}")"
  if [[ -n "${prev}" ]]; then
    read -r -s -p "${prompt} [оставьте пустым, чтобы использовать сохранённый]: " input || true
    echo
    input="${input:-${prev}}"
  else
    read -r -s -p "${prompt}: " input || true
    echo
  fi
  [[ -n "${input}" ]] || die "Секретное значение для ${var_name} обязательно."
  printf -v "${var_name}" '%s' "${input}"
  export "${var_name}"
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

# ---------- 0. root & prerequisites ----------
require_root
mkdir -p "${SECRETS_DIR}"
chmod 700 "${SECRETS_DIR}"

# Если конфиг уже есть — предлагаем использовать его или перезаписать
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

ask ADMIN_USER "Имя административного пользователя (будет создан/использован)" "anton"
ask SSH_PORT "Порт SSH" "22"
ask WG_PORT "UDP-порт WireGuard" "51820"
ask WG_NETWORK "Подсеть WireGuard (CIDR)" "10.8.0.0/24"
ask SERVER_IP "Публичный IP сервера (оставьте пустым для автоопределения)" ""

if [[ -z "${SERVER_IP}" ]]; then
  SERVER_IP="$(curl -4 -fsS https://ifconfig.me 2>/dev/null || true)"
  [[ -n "${SERVER_IP}" ]] || die "Не удалось определить публичный IP. Укажите SERVER_IP вручную."
  log "Автоопределён SERVER_IP=${SERVER_IP}"
fi

ask_secret WG_PRIVATE_KEY "Приватный ключ WireGuard (оставьте пустым для генерации нового)" || true
# если ключа нет — сгенерируем позже; пока просто запомним, что его нет

# ---------- 2. сохранение конфига ----------
log "Шаг 2/5: Сохранение конфигурации."
write_env ADMIN_USER      "${ADMIN_USER}"
write_env SSH_PORT        "${SSH_PORT}"
write_env WG_PORT         "${WG_PORT}"
write_env WG_NETWORK      "${WG_NETWORK}"
write_env SERVER_IP       "${SERVER_IP}"
# приватный ключ сохраним после генерации (шаг 4)

# симлинк .env в корне репозитория
if [[ -L "${ENV_LINK}" || -f "${ENV_LINK}" ]]; then
  log "${ENV_LINK} уже существует — оставляем как есть."
else
  ln -s "${CONFIG_FILE}" "${ENV_LINK}"
  log "Создан симлинк ${ENV_LINK} -> ${CONFIG_FILE}"
fi

# ---------- 3. базовый hardening ----------
log "Шаг 3/5: Базовый hardening (обновления, UFW, fail2ban, SSH)."

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y

# UFW
if ! command -v ufw >/dev/null 2>&1; then
  apt-get install -y ufw
fi
ufw --force default deny incoming
ufw --force default allow outgoing
ufw allow "${SSH_PORT}/tcp" comment 'SSH'
ufw allow "${WG_PORT}/udp" comment 'WireGuard'
ufw --force enable
log "UFW настроен: deny incoming, allow ${SSH_PORT}/tcp, ${WG_PORT}/udp."

# fail2ban
if ! dpkg -s fail2ban >/dev/null 2>&1; then
  apt-get install -y fail2ban
fi
systemctl enable --now fail2ban
log "fail2ban установлен и запущен."

# SSH hardening (осторожно: не блокируем текущую сессию)
SSHD_CONFIG="/etc/ssh/sshd_config.d/99-server-infra.conf"
cat > "${SSHD_CONFIG}" <<EOF
Port ${SSH_PORT}
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
EOF
# проверим синтаксис перед рестартом
if sshd -t; then
  systemctl reload ssh
  log "SSH hardening применён (порт ${SSH_PORT}, root login запрещён)."
else
  warn "sshd -t не прошёл. Файл ${SSHD_CONFIG} создан, но рестарт не выполнен."
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
    $(. /etc/os-release && echo "${VERSION_CODENAME}") stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
  log "Docker установлен."
fi

# ---------- 5. WireGuard ----------
log "Шаг 5/5: Установка и настройка WireGuard."
if ! dpkg -s wireguard >/dev/null 2>&1; then
  apt-get install -y wireguard
fi

WG_DIR="/etc/wireguard"
mkdir -p "${WG_DIR}"
chmod 700 "${WG_DIR}"

WG_PRIV_FILE="${WG_DIR}/privatekey"
WG_PUB_FILE="${WG_DIR}/publickey"

if [[ ! -f "${WG_PRIV_FILE}" ]]; then
  # если пользователь ввёл ключ — используем его, иначе генерируем
  if [[ -n "${WG_PRIVATE_KEY:-}" ]]; then
    echo "${WG_PRIVATE_KEY}" > "${WG_PRIV_FILE}"
  else
    wg genkey > "${WG_PRIV_FILE}"
  fi
  chmod 600 "${WG_PRIV_FILE}"
  wg pubkey < "${WG_PRIV_FILE}" > "${WG_PUB_FILE}"
  log "Сгенерирована пара ключей WireGuard."
else
  log "Приватный ключ WireGuard уже существует."
fi

# сохраняем приватный ключ в конфиг (зашифрованно не будем — уже chmod 600)
WG_PRIVATE_KEY="$(cat "${WG_PRIV_FILE}")"
write_env WG_PRIVATE_KEY "${WG_PRIVATE_KEY}"

# базовый конфиг wg0 (без peers — peers добавляются позже скриптом wireguard-add-client)
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

echo "=== Bootstrap completed at $(date -Is) ==="
echo "Конфигурация: ${CONFIG_FILE}"
echo "Симлинк: ${ENV_LINK}"
echo "Лог: ${LOG_FILE}"
