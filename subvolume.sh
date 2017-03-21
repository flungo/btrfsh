# Determine the command
COMMAND="$1"
shift

case "${COMMAND}" in
  backup)
    source "${BTRFSH_DIR}/subvolume/backup.sh"
    ;;
  *)
    >&2 usage
    exit 1
    ;;
esac
