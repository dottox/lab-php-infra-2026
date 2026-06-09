#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/opt/proconnect"
COMPOSE="docker compose -f docker-compose.yml"

cd "$APP_DIR"

if [ ! -f .env ]; then
  echo "ERROR: .env file not found in $APP_DIR"
  exit 1
fi

set -a
source .env
set +a

echo "==> Pull images"
$COMPOSE pull

echo "==> Start postgres and redis first"
$COMPOSE up -d postgres redis

echo "==> Wait for PostgreSQL"

MAX_RETRIES=45
RETRY=0

until $COMPOSE exec -T postgres pg_isready -U "$DB_USERNAME" -d "$DB_DATABASE" >/dev/null 2>&1; do
  RETRY=$((RETRY + 1))

  if [ "$RETRY" -ge "$MAX_RETRIES" ]; then
    echo "ERROR: PostgreSQL did not become ready in time"

    echo "==> Postgres status"
    $COMPOSE ps postgres || true

    echo "==> Postgres logs"
    $COMPOSE logs --tail=120 postgres || true

    exit 1
  fi

  echo "Waiting for PostgreSQL... ($RETRY/$MAX_RETRIES)"
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
