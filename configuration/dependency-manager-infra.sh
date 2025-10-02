#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# ==================== Конфигурация ====================
: "${REPO_URL:=https://github.com/Asteises/dependency-manager-infrastructure.git}"
: "${REPO_DIR:=/opt/dependency-manager-infrastructure}"

: "${DEV_TARGET_APP_DIR:=/opt/dependency-manager/dev}"
: "${PROD_TARGET_APP_DIR:=/opt/dependency-manager/prod}"

: "${DEV_NGINX_CONF_TARGET:=/etc/nginx/conf.d/dm-test.asteises.ru.conf}"
: "${PROD_NGINX_CONF_TARGET:=/etc/nginx/conf.d/dm.asteises.ru.conf}"

# Ветка/тег/коммит. Пример: DM_INFRA_REF=main или v1.2.3 или 1a2b3c4d
: "${DM_INFRA_REF:=master}"

# Использовать ли шаблоны .tpl с envsubst (1/0)
: "${USE_TEMPLATES:=0}"

# Лог и лок
LOG_DIR="/var/log/dm-infra"
LOG_FILE="${LOG_DIR}/update-$(date +%F_%H%M%S).log"
LOCK_FILE="/var/lock/dm-infra.lock"

# Домены (для шаблонов)
: "${DEV_DOMAIN:=dm-test.asteises.ru}"
: "${PROD_DOMAIN:=dm.asteises.ru}"

# ==================== Утилиты ====================
req() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found"; exit 1; }; }
log() { echo "[$(date +%F\ %T)] $*" | tee -a "$LOG_FILE"; }

# ==================== Стартовые проверки ====================
[ "$(id -u)" -eq 0 ] || { echo "Run as root"; exit 1; }
mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1
req git; req nginx; req install; req awk; req sed
[ "$USE_TEMPLATES" -eq 0 ] || req envsubst

# Блокировка
exec 9>"$LOCK_FILE"
flock -n 9 || { echo "Another instance is running"; exit 1; }

log "=============================="
log "🚀 Обновление инфраструктуры Dependency Manager"
log "Дата: $(date)"
log "Репозиторий: $REPO_URL @ $DM_INFRA_REF"
log "Лог: $LOG_FILE"
log "=============================="

git config --global --add safe.directory "$REPO_DIR" || true

# Директории
install -d "$REPO_DIR" "$DEV_TARGET_APP_DIR" "$PROD_TARGET_APP_DIR"

# ==================== Git sync ====================
if [ ! -d "$REPO_DIR/.git" ]; then
  log "[INFO] Клонируем репозиторий в $REPO_DIR"
  rm -rf "$REPO_DIR" || true
  git clone --depth=1 --branch "$DM_INFRA_REF" "$REPO_URL" "$REPO_DIR"
else
  log "[INFO] Обновляем репозиторий…"
  cd "$REPO_DIR"
  if ! git diff --quiet || ! git diff --cached --quiet; then
    log "[WARN] Локальные изменения — складываю в stash"
    git stash push -u -m "auto-$(date +%F_%T)" || true
  fi
  git fetch --prune origin
  # Переключаемся на нужную ссылку
  if git show-ref --verify --quiet "refs/heads/$DM_INFRA_REF"; then
    git checkout "$DM_INFRA_REF"
    git reset --hard "origin/$DM_INFRA_REF"
  else
    git fetch --tags origin
    git checkout "$DM_INFRA_REF" || git checkout -B temp "$DM_INFRA_REF"
    git reset --hard "$DM_INFRA_REF" || true
  fi
  git clean -fdx
fi

changed=0

# ==================== Функции копирования ====================
# атомарная замена: кладём во временный и mv поверх
atomic_install() {
  local src="$1" dst="$2" mode="$3"
  local tmp="${dst}.tmp.$$"
  install -m "$mode" "$src" "$tmp"
  if [ ! -f "$dst" ] || ! cmp -s "$tmp" "$dst"; then
    # бэкап старого (если есть)
    if [ -f "$dst" ]; then
      cp -a "$dst" "${dst}.bak-$(date +%F_%H%M%S)"
    fi
    mv -f "$tmp" "$dst"
    log "[CHANGED] $dst"
    changed=1
  else
    rm -f "$tmp"
    log "[SKIP]    $dst (без изменений)"
  fi
}

render_tpl() {
  # render_tpl template.tpl /path/result.conf 0644
  local tpl="$1" dst="$2" mode="$3"
  local tmp="${dst}.tmp.$$"
  envsubst < "$tpl" > "$tmp"
  if [ ! -f "$dst" ] || ! cmp -s "$tmp" "$dst"; then
    [ -f "$dst" ] && cp -a "$dst" "${dst}.bak-$(date +%F_%H%M%S)"
    mv -f "$tmp" "$dst"
    chmod "$mode" "$dst"
    log "[CHANGED] $dst (template)"
    changed=1
  else
    rm -f "$tmp"
    log "[SKIP]    $dst (template, без изменений)"
  fi
}

# ==================== Раскладка файлов ====================
cd "$REPO_DIR"

# docker-compose для DEV/PROD
atomic_install "$REPO_DIR/configuration/docker-compose.yml" "$DEV_TARGET_APP_DIR/docker-compose.yml" 0644
atomic_install "$REPO_DIR/configuration/dependency-manager-deploy.sh" "$DEV_TARGET_APP_DIR/dependency-manager-deploy.sh" 0755

atomic_install "$REPO_DIR/configuration/dependency-manager-deploy.sh" "$PROD_TARGET_APP_DIR/dependency-manager-deploy.sh" 0755
atomic_install "$REPO_DIR/configuration/docker-compose.yml" "$PROD_TARGET_APP_DIR/docker-compose.yml" 0644

# Nginx конфиги: либо из готовых файлов, либо из шаблонов
if [ "$USE_TEMPLATES" -eq 1 ]; then
  export DEV_DOMAIN PROD_DOMAIN
  render_tpl "$REPO_DIR/configuration/nginx/dev.conf.tpl"  "$DEV_NGINX_CONF_TARGET"  0644
  render_tpl "$REPO_DIR/configuration/nginx/prod.conf.tpl" "$PROD_NGINX_CONF_TARGET" 0644
else
  atomic_install "$REPO_DIR/configuration/nginx/dm-test.asteises.ru.conf" "$DEV_NGINX_CONF_TARGET" 0644
  atomic_install "$REPO_DIR/configuration/nginx/dm.asteises.ru.conf" "$PROD_NGINX_CONF_TARGET" 0644
fi

# ==================== Проверка и перезагрузка Nginx ====================
log "[INFO] Проверка конфигурации Nginx…"
if ! nginx -t; then
  log "[ERROR] Nginx конфиг битый. Откатывает перезапуск. Исправьте и запустите скрипт снова."
  exit 1
fi

if [ "$changed" -eq 1 ]; then
  log "[INFO] Изменения обнаружены — перезагружаю Nginx"
  systemctl reload nginx
else
  log "[INFO] Изменений нет — перезагрузка Nginx не требуется"
fi

log "✅ Готово! Инфраструктура актуальна."