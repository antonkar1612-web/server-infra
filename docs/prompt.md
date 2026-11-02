# Промт-блок для нового чата (server-infra v1.0.2)

Вставьте блок ниже в начало чата с ассистентом.

## Контекст: server-infra (базовая инфраструктура) — v1.0.2

- Репозиторий: https://github.com/antonkar1612-web/server-infra
- Назначение: bash-скрипты установки ОС (hardening, Docker, fail2ban, UFW,
  SSH). Опционально — WireGuard. Код приложений сюда не входит.
- Скрипт `bootstrap.sh` v5:
  - вход по паролю: `ssh anton@<SERVER_IP>`;
  - SSH-ключи НЕ настраиваются (пользователь работает с разных мест);
  - `PermitRootLogin no`, `PasswordAuthentication yes`;
  - `anton` в группе sudo. **Пароль `anton` скрипт НЕ задаёт** —
    только предупреждает (`passwd -S`). Задайте `passwd anton`
    **до** reload SSH, иначе после `PermitRootLogin no` потеряете доступ;
  - идемпотентен: при повторном запуске предлагает использовать
    сохранённые значения из `/root/secrets/server-infra.env` (chmod 600),
    симлинк `./.env -> /root/secrets/server-infra.env`.
- Секреты: только `/root/secrets/`, никогда в Git. `.env.example` в репо.
- Лог: `/root/server-infra-bootstrap.log`, диагностика по шагам `Шаг X/5`.
- Теги: `v1.0.0` — первое успешное развёртывание;
  `v1.0.1` — пароль вместо ключей, umask 077;
  `v1.0.2` — фикс `OS_CODENAME`, флаг `INSTALL_WG`.

## Флаг INSTALL_WG

- `INSTALL_WG=yes` (по умолчанию) — ставит WireGuard: пакет, ключи,
  `/etc/wireguard/wg0.conf`, `wg-quick@wg0`, UFW `WG_PORT/udp`.
- `INSTALL_WG=no` — шаг 5 полностью пропускается, WG-вопросы не задаются,
  UFW открывает только SSH. Используется в текущем развёртывании на
  `forcibly`.
- Пример: `sudo INSTALL_WG=no ./bootstrap.sh`.

## fail2ban (sshd jail)

- Дефолт Ubuntu 24.04: maxretry=5, findtime=10m, bantime=10m.
- Фон на порту 22: ~200 попыток входа за 10 минут, 3-4 IP в бане — норма.
- Риск при работе с разных мест: 5 опечаток с одного IP → бан 10 мин.
- Разбан: `fail2ban-client unban --all` (или с другого IP / через VNC
  провайдера).
- Смену SSH-порта не предлагать без явного запроса.

## Известные грабли

- `wg genkey > file` создаёт файл с umask 022 → оборачивать в
  `( umask 077; wg genkey > file )`.
- `ask` с пустым дефолтом требует 4-й параметр `optional` (SERVER_IP,
  автоопределение через ifconfig.me).
- **`SERVER_IP` при запуске указывайте вручную** — автоопределение через
  `ifconfig.me` может вернуть не тот адрес (актуально для VPS с
  несколькими IP; на `forcibly` primary `109.172.92.118` заблокирован,
  рабочий — `153.56.134.175`).
- `exec > >(tee -a log)` склеивает промпты в логе — это нормально,
  диагностировать по `Шаг X/5`.
- `apparmor.postinst: [: Illegal number: yes` — известный баг Ubuntu
  24.04, к скрипту отношения не имеет.
- `OS_CODENAME: unbound variable` в v1.0.1 — фикс в v1.0.2 через
  `. /etc/os-release` + `VERSION_CODENAME`.

## Правила для ассистента

- Не предлагать: Python 3.14, Cohere, LangGraph, голые bash-скрипты
  вместо Docker, SSH-ключи вместо пароля.
- При изменении скриптов сохранять идемпотентность и `bash -n`.
- Новые сервисы — по паттерну `server-services/services/<name>/` +
  блок в `docker-compose.yml`.
- Учитывать бесплатный лимит OpenRouter (50 запросов/день).
