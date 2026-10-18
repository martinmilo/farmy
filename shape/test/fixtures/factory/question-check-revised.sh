case "$(cat src/app.txt)" in
  fixed) printf '%s\n' 'Captured worker greeting is fixed; reviewed answer requires resolved.'; exit 1 ;;
  resolved|broken) exit 0 ;;
  *) exit 2 ;;
esac
