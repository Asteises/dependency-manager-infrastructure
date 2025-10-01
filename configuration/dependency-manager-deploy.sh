#!/bin/bash
set -e

### ================================
### 0. Параметры запуска
### ================================

BRANCH_BACKEND="${1:-dev}"
BRANCH_FRONTEND="${2:-dev}"
CLEAN_IMAGES="${3:-yes}"

### ================================
### 1. Пути и переменные
### ================================

APP_ROOT="/opt/dependency-manager"

BACKEND_REPO_URL="https://github.com/KovtunovRoman/dependency-manager.git"
FRONTEND_REPO_URL="git@github.com:Asteises/dependency-manager-infrastructure.git"

BACKEND_DIR="${APP_ROOT}/backend"
FRONTEND_DIR="${APP_ROOT}/frontend"
FRONTEND_DIST_DIR="/var/www/dm/js"
COMPOSE_FILE="${APP_ROOT}/docker-compose.yml"

IMAGE_NAME="dependency-manager"
DATE_TAG=$(date +'%Y%m%d%H%M%S')
BACKEND_TAG="${IMAGE_NAME}:${DATE_TAG}"

FRONTEND_BUILD_IMAGE="dependency-manager-frontend-builder"
FRONTEND_EXPORT_CONTAINER="dependency-manager-frontend-export"

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
cd "$BACKEND_DIR"
echo "[BACKEND] Обновляем репозиторий..."
git fetch origin
git reset --hard "origin/$BRANCH_BACKEND"

# Frontend
if [ ! -d "$FRONTEND_DIR" ]; then
  echo "[FRONTEND] Клонируем $FRONTEND_REPO_URL..."
  git clone -b "$BRANCH_FRONTEND" "$FRONTEND_REPO_URL" "$FRONTEND_DIR"
else
  echo "[FRONTEND] Обновляем репозиторий..."
  cd "$FRONTEND_DIR"
  git fetch origin
  git reset --hard "origin/$BRANCH_FRONTEND"
fi

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
sed -i "s|image: ${IMAGE_NAME}:.*|image: ${BACKEND_TAG}|g" "$COMPOSE_FILE"

echo "[BACKEND] Перезапускаем контейнер..."
docker-compose -f "$COMPOSE_FILE" stop backend
docker-compose -f "$COMPOSE_FILE" up -d backend

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
