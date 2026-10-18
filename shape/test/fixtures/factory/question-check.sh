case "$(cat src/app.txt)" in
  fixed) printf '%s\n' 'Expected the answer to resolve the captured worker greeting.'; exit 1 ;;
  resolved|broken) exit 0 ;;
  *) exit 2 ;;
esac
