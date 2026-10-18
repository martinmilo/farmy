if [ "$(cat src/app.txt)" = fixed ]; then
  exit 0
fi
printf '%s\n' 'Greeting mismatch: expected fixed in src/app.txt.'
exit 1
