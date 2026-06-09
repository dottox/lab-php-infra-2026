#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/opt/proconnect"
COMPOSE="docker compose -f docker-compose.yml"

cd "$APP_DIR"

echo "==> Pull images"
$COMPOSE pull

echo "==> Start postgres and redis first"
$COMPOSE up -d postgres redis

echo "==> Wait for PostgreSQL"
until $COMPOSE exec -T postgres pg_isready -U "$DB_USERNAME" -d "$DB_DATABASE" >/dev/null 2>&1; do
  echo "Waiting for PostgreSQL..."
  sleep 2
done

echo "==> Start application stack"
$COMPOSE up -d

echo "==> Wait backend boot"
sleep 10

echo "==> Clear Laravel caches"
$COMPOSE exec -T backend php artisan optimize:clear || true

echo "==> Database setup"

if [ "${DB_FRESH_SEED:-false}" = "true" ]; then
  echo "WARNING: DB_FRESH_SEED=true -> running migrate:fresh --seed"
  $COMPOSE exec -T backend php artisan migrate:fresh --seed --force
else
  echo "Running safe migrations"
  $COMPOSE exec -T backend php artisan migrate --force

  if [ "${DB_SEED:-false}" = "true" ]; then
    echo "DB_SEED=true -> running db:seed"
    $COMPOSE exec -T backend php artisan db:seed --force
  fi
fi

echo "==> Storage link"
$COMPOSE exec -T backend php artisan storage:link || true

echo "==> Cache Laravel"
$COMPOSE exec -T backend php artisan config:cache
$COMPOSE exec -T backend php artisan route:cache
$COMPOSE exec -T backend php artisan view:cache

if $COMPOSE config --services | grep -q '^horizon$'; then
  echo "==> Restart Horizon gracefully"
  $COMPOSE exec -T backend php artisan horizon:terminate || true
  $COMPOSE restart horizon || true
fi

if $COMPOSE config --services | grep -q '^scheduler$'; then
  echo "==> Restart scheduler"
  $COMPOSE restart scheduler || true
fi

echo "==> Containers status"
$COMPOSE ps

echo "==> Cleanup old images"
docker image prune -f

echo "==> Deploy finished"
