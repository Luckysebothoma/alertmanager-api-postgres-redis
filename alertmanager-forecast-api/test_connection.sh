CONTAINER=alertmanager-forecast-api_postgres.1.8ro7sctbouc49jwp5v4rx0q92

echo "--- postgres (superuser) ---"
PGPASSWORD="$(cat secrets/pg_root_password.txt)" \
  docker exec -e PGPASSWORD -i "$CONTAINER" psql -U postgres -d forecast -c '\conninfo'

echo "--- app_user ---"
PGPASSWORD="$(cat secrets/app_db_password.txt)" \
  docker exec -e PGPASSWORD -i "$CONTAINER" psql -U app_user -d forecast -c '\conninfo'

echo "--- monitoring_ro ---"
PGPASSWORD="$(cat secrets/monitoring_db_password.txt)" \
  docker exec -e PGPASSWORD -i "$CONTAINER" psql -U monitoring_ro -d forecast -c '\conninfo'

echo "--- backup_ro ---"
PGPASSWORD="$(cat secrets/backup_db_password.txt)" \
  docker exec -e PGPASSWORD -i "$CONTAINER" psql -U backup_ro -d forecast -c '\conninfo'
