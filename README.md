# server-infra

Bash-скрипты установки ОС: hardening, Docker, fail2ban, UFW, SSH.
Опционально — WireGuard (по умолчанию **включён**, но легко отключается).
Код приложений не входит — см. server-services и integration_service.

## Запуск

    sudo ./bootstrap.sh                # обычная установка (с WireGuard)
    sudo INSTALL_WG=no ./bootstrap.sh  # без WireGuard

Скрипт идемпотентен: использует сохранённые значения из
`/root/secrets/server-infra.env` (chmod 600), симлинк `./.env`.

### Флаги

| Переменная | По умолчанию | Описание |
|---|---|---|
| `INSTALL_WG` | `yes` | Ставить ли WireGuard (пакет, ключи, `wg0.conf`, `wg-quick@wg0`, UFW UDP). `no` — полностью пропустить шаг 5. |

### На что обратить внимание

- `SERVER_IP` при запуске указывайте **вручную** — автоопределение через
  `ifconfig.me` может вернуть не тот адрес (актуально для VPS с несколькими IP).
- Пользователь `ADMIN_USER` создаётся, но **пароль не задаётся** —
  задайте его `passwd anton` **до** перезапуска SSH, иначе после
  `PermitRootLogin no` потеряете доступ.

## Вход

    ssh anton@<SERVER_IP>   # по паролю

`PermitRootLogin no`, `PasswordAuthentication yes`.
SSH-ключи не используются: работа с разных мест.

## Секреты

Только `/root/secrets/`, никогда в Git.

## fail2ban

Если попали в бан после 5 неудачных попыток — войти с другого IP
или через веб-консоль провайдера (VNC):

    fail2ban-client unban --all

## Промт для нового чата

См. `docs/prompt.md`.
