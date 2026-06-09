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

echo "==> Run Laravel preparation using one-off containers"

echo "==> Clear Laravel caches"
$COMPOSE run --rm backend php artisan optimize:clear || true

echo "==> Database setup"

if [ "${DB_FRESH_SEED:-false}" = "true" ]; then
  echo "WARNING: DB_FRESH_SEED=true -> running migrate:fresh --force"
  echo "WARNING: This will DROP all tables in database: $DB_DATABASE"
  $COMPOSE run --rm backend php artisan migrate:fresh --force
else
  echo "Running safe migrations"
  $COMPOSE run --rm backend php artisan migrate --force

  if [ "${DB_SEED:-false}" = "true" ]; then
    echo "DB_SEED=true -> running db:seed"
    $COMPOSE run --rm backend php artisan db:seed --force
  fi
fi

echo "==> Storage link"
$COMPOSE run --rm backend php artisan storage:link || true

echo "==> Cache Laravel"
$COMPOSE run --rm backend php artisan config:cache
$COMPOSE run --rm backend php artisan route:cache
$COMPOSE run --rm backend php artisan view:cache

echo "==> Start application stack"
$COMPOSE up -d

if $COMPOSE config --services | grep -q '^horizon$'; then
  echo "==> Restart Horizon gracefully"
  $COMPOSE run --rm backend php artisan horizon:terminate || true
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
