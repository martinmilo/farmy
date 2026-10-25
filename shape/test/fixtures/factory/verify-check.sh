# The expectation, kept from the agent: src/app.txt says fixed.
printf 'args:'
printf ' [%s]' "$@"
printf '\n'
echo "checking src/app.txt" >&2
if grep -q fixed src/app.txt; then
  echo "src/app.txt says fixed"
else
  echo "src/app.txt does not say fixed yet"
  exit 3
fi
