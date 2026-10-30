# server-infra

Bash-скрипты установки ОС: hardening, Docker, WireGuard.
Код приложений не входит — см. server-services и integration_service.

## Запуск

    sudo ./bootstrap.sh

Скрипт идемпотентен: использует сохранённые значения из
~/secrets/server-infra.env (chmod 600), симлинк ./.env.

## Вход

ssh anton@<SERVER_IP> — по паролю.
PermitRootLogin no, PasswordAuthentication yes.
SSH-ключи не используются: работа с разных мест.

## Секреты

Только ~/secrets/, никогда в Git.

## fail2ban

Если попали в бан после 5 неудачных попыток — войти с другого IP
или через веб-консоль провайдера (VNC):

    fail2ban-client unban --all

## Промт для нового чата

См. docs/prompt.md
