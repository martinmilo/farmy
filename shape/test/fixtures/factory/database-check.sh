set -eu
marker=$(cat src/app.txt)
psql -h postgres -U dev -d app -c "INSERT INTO gate_values (value) VALUES ('$marker')"
test "$(psql -h postgres -U dev -d app -Atc 'SELECT value FROM gate_values ORDER BY value')" = "$marker"
while [ "$(psql -h postgres -U dev -d app -Atc 'SELECT count(*) FROM gate_release')" != 1 ]; do
  sleep 0.05
done
test "$(psql -h postgres -U dev -d app -Atc 'SELECT value FROM gate_values ORDER BY value')" = "$marker"
printf 'Database contains only %s after release.\n' "$marker"
