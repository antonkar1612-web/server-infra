# Промт-блок для нового чата (server-infra v1.0.0)

Вставьте блок ниже в начало чата с ассистентом.

## Контекст: server-infra (базовая инфраструктура) — v1.0.0

- Репозиторий: https://github.com/antonkar1612-web/server-infra
- Назначение: bash-скрипты установки ОС (hardening, Docker, WireGuard).
  Код приложений сюда не входит.
- Скрипт `bootstrap.sh` v5:
  - вход по паролю: `ssh anton@<SERVER_IP>`;
  - SSH-ключи НЕ настраиваются (пользователь работает с разных мест);
  - `PermitRootLogin no`, `PasswordAuthentication yes`;
  - `anton` в группе sudo, пароль задаётся в скрипте (chpasswd) или
    вручную `passwd anton` — проверка через `passwd -S`;
  - идемпотентен: при повторном запуске предлагает использовать
    сохранённые значения из `~/secrets/server-infra.env` (chmod 600),
    симлинк `./.env -> ~/secrets/server-infra.env`.
- Секреты: только `~/secrets/`, никогда в Git. `.env.example` в репо.
- Лог: `/root/server-infra-bootstrap.log`, диагностика по шагам `Шаг X/5`.
- Теги: `v1.0.0` — первое успешное развёртывание.

## fail2ban (sshd jail)

- Дефолт Ubuntu 24.04: maxretry=5, findtime=10m, bantime=10m.
- Фон на порту 22: ~200 попыток входа за 10 минут, 3-4 IP в бане — норма.
- Риск при работе с разных мест: 5 опечаток с одного IP → бан 10 мин.
- Разбан: `docs/fail2ban-unban.md` (залогинен / веб-консоль провайдера /
  другой IP).
- Смену SSH-порта не предлагать без явного запроса.

## Известные грабли

- `wg genkey > file` создаёт файл с umask 022 → оборачивать в
  `( umask 077; wg genkey > file )`.
- `ask` с пустым дефолтом требует 4-й параметр `optional` (SERVER_IP,
  автоопределение через ifconfig.me).
- `exec > >(tee -a log)` склеивает промпты в логе — это нормально,
  диагностировать по `Шаг X/5`.
- `apparmor.postinst: [: Illegal number: yes` — известный баг Ubuntu
  24.04, к скрипту отношения не имеет.

## Правила для ассистента

- Не предлагать: Python 3.14, Cohere, LangGraph, голые bash-скрипты
  вместо Docker, SSH-ключи вместо пароля.
- При изменении скриптов сохранять идемпотентность.
- Новые сервисы — по паттерну `server-services/services/<name>/` +
  блок в `docker-compose.yml`.
- Учитывать бесплатный лимит OpenRouter (50 запросов/день).
