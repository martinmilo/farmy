if [ "$(cat src/app.txt)" = fixed ]; then
  exit 0
fi
printf '%s\n' 'Expected src/app.txt to say fixed; the implementation still says broken.'
exit 1
