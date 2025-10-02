#!/bin/bash
set -e

### ================================
### 0. Параметры запуска
### ================================

BRANCH_BACKEND="${1:-dev}"
BRANCH_FRONTEND="${2:-dev}"
CLEAN_IMAGES="${3:-yes}"

### ================================
### 1.1 Пути и переменные
### ================================

APP_ROOT="/opt/dependency-manager"

BACKEND_REPO_URL="git@github-kovtunov:KovtunovRoman/dependency-manager.git"
FRONTEND_REPO_URL="git@github-asteises:Asteises/dependency-manager-vue-ui.git"

BACKEND_DIR="${APP_ROOT}/backend"
FRONTEND_DIR="${APP_ROOT}/frontend"
FRONTEND_DIST_DIR="/var/www/dm/js"
COMPOSE_FILE="$(cd "$(dirname "$0")" && pwd)/docker-compose.yml"

IMAGE_NAME="dependency-manager"
DATE_TAG=$(date +'%Y%m%d%H%M%S')
BACKEND_TAG="${IMAGE_NAME}:${DATE_TAG}"

FRONTEND_BUILD_IMAGE="dependency-manager-frontend-builder"
FRONTEND_EXPORT_CONTAINER="dependency-manager-frontend-export"

### ================================
### 1.2 Подготовка каталогов
### ================================
echo "=============================="
echo "${LOG_TAG} Инициализируем переменные и подготавливаем директории..."

mkdir -p "${APP_ROOT}" "${BACKEND_DIR}" "${FRONTEND_DIR}" "$(dirname "${FRONTEND_DIST_DIR}")" "${FRONTEND_DIST_DIR}"

### ================================
### 2. Логирование
### ================================

echo "=============================="
echo "DEPLOY START: $(date)"
echo "Branch backend: $BRANCH_BACKEND"
echo "Branch frontend: $BRANCH_FRONTEND"
echo "Backend tag: $BACKEND_TAG"
echo "Clean old images: $CLEAN_IMAGES"
echo "=============================="

### ================================
### 3. Обновление репозиториев
### ================================

# Backend
if [ ! -d "$BACKEND_DIR/.git" ]; then
  echo "[BACKEND] Репозиторий не инициализирован — клонируем..."
  rm -rf "$BACKEND_DIR" && mkdir -p "$BACKEND_DIR"
  git clone -b "$BRANCH_BACKEND" "$BACKEND_REPO_URL" "$BACKEND_DIR"
fi

cd "$BACKEND_DIR"
echo "[BACKEND] Обновляем репозиторий..."
git fetch origin
git reset --hard "origin/$BRANCH_BACKEND"

# Frontend
if [ ! -d "$FRONTEND_DIR/.git" ]; then
  echo "[FRONTEND] Репозиторий не инициализирован — клонируем..."
  rm -rf "$FRONTEND_DIR" && mkdir -p "$FRONTEND_DIR"
  git clone -b "$BRANCH_FRONTEND" "$FRONTEND_REPO_URL" "$FRONTEND_DIR"
fi

echo "[FRONTEND] Обновляем репозиторий..."
cd "$FRONTEND_DIR"
git fetch origin
git reset --hard "origin/$BRANCH_FRONTEND"

### ================================
### 4. Сборка frontend внутри Docker
### ================================

cd "$FRONTEND_DIR"

echo "[FRONTEND] Собираем билд-контейнер..."
docker build -t "$FRONTEND_BUILD_IMAGE" .

echo "[FRONTEND] Копируем dist/ из контейнера..."

# Удалим старую папку dist
rm -rf "$FRONTEND_DIST_DIR"
mkdir -p "$FRONTEND_DIST_DIR"

# Создадим временный контейнер из builder-имиджа
docker create --name "$FRONTEND_EXPORT_CONTAINER" "$FRONTEND_BUILD_IMAGE"

# Скопируем папку /export (из export stage)
docker cp "$FRONTEND_EXPORT_CONTAINER:/export/." "$FRONTEND_DIST_DIR"

# Удалим временный контейнер
docker rm "$FRONTEND_EXPORT_CONTAINER"

echo "[FRONTEND] Готово: dist скопирован в $FRONTEND_DIST_DIR"

### ================================
### 5. Сборка и перезапуск backend
### ================================

cd "$BACKEND_DIR"

echo "[BACKEND] Собираем Docker-образ: $BACKEND_TAG"
docker build -t "$BACKEND_TAG" .

echo "[BACKEND] Обновляем тег в docker-compose.yml"
# 1) Если в compose у backend уже есть image: <что-то>, просто переопределим
if awk '/^services:/,/^[^ ]/{if($0~/^  backend:/){inb=1; next} if(inb&&$0~/^[^ ]/){inb=0} if(inb&&$0~/^[[:space:]]*image:/){found=1}} END{exit found?0:1}' "$COMPOSE_FILE"; then
  # внутри блока services.backend заменим строку image: на наш тег
  sed -i -E '/^services:/,/^[^ ]/{
    /^  backend:/,/^[^ ]/{
      s|^[[:space:]]*image:.*$|    image: '"${BACKEND_TAG}"'|
    }
  }' "$COMPOSE_FILE"
else
  # 2) Если строки image: нет — создаём override с нужным образом
  OVERRIDE_FILE="$(dirname "$COMPOSE_FILE")/docker-compose.override.yml"
  cat > "$OVERRIDE_FILE" <<EOF
services:
  backend:
    image: ${BACKEND_TAG}
EOF
  echo "[BACKEND] Создан ${OVERRIDE_FILE} для переопределения образа backend."
fi

echo "[BACKEND] Перезапускаем контейнер..."
OVERRIDE_FILE="$(dirname "$COMPOSE_FILE")/docker-compose.override.yml"

if [ -f "$OVERRIDE_FILE" ]; then
  docker-compose -f "$COMPOSE_FILE" -f "$OVERRIDE_FILE" stop backend || true
  docker-compose -f "$COMPOSE_FILE" -f "$OVERRIDE_FILE" up -d backend
else
  docker-compose -f "$COMPOSE_FILE" stop backend || true
  docker-compose -f "$COMPOSE_FILE" up -d backend
fi

### ================================
### 6. Очистка старых образов
### ================================

if [ "$CLEAN_IMAGES" = "yes" ]; then
  echo "[CLEANUP] Очистка старых образов backend..."
  docker images "$IMAGE_NAME" --format "{{.Repository}}:{{.Tag}}" | sort -r | tail -n +6 | xargs -r docker rmi

  echo "[CLEANUP] Очистка сборочных образов frontend..."
  docker images "$FRONTEND_BUILD_IMAGE" --format "{{.Repository}}:{{.Tag}}" | tail -n +6 | xargs -r docker rmi
fi

echo "=============================="
echo "DEPLOY COMPLETED: $(date)"
echo "=============================="
