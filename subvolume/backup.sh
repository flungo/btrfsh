require_root

backup_subvolume(){
  if [ $# -lt 1 ] || [ -z "$1" ]; then
    >&2 echo "backup requires one argument"
    return 1
  fi

  # Read the argument
  SUBVOL=$(readlink -f "$1")

  if [ "$SUBVOL" == "$BACKUP_DIR" ]; then
    >&2 echo "Cannot snapshot the backup directory"
    return 1
  fi

  if ! is_subvolume $SUBVOL; then
    >&2 echo "$SUBVOL: Not a subvolume"
    return 1
  fi

  SNAPSHOT="$(readlink -f "$SUBVOL/.snapshot")"
  SNAPSHOT_TMP="$(readlink -f "${SNAPSHOT}-tmp")"

  # Prepare tree to SUBVOL_BACKUP_DIR
  prepare_backup_dir "$SUBVOL"

  # Determine where we are backing up to
  SUBVOL_BACKUP_DIR="$(readlink -f "${BACKUP_DIR}${SUBVOL}")"
  BACKUP_SNAPSHOT="$(readlink -f "${SUBVOL_BACKUP_DIR}/$(date -u +${BACKUP_DATE_FORMAT})")"

  # If the destination exists, stop
  if [ -e "$BACKUP_SNAPSHOT" ]; then
    >&2 echo "$SUBVOL_BACKUP_DIR: Backup destination already exists"
    return 1
  fi

  # Check preparation was successful
  if ! [ -e "$SUBVOL_BACKUP_DIR" ]; then
    >&2 echo "Failed to prepare backup directory"
    return 1
  fi

  # Check that the backup dir doesn't have folders named SNAPSHOT_DIR or SNAPSHOT_TMP_DIR
  if [ -e "$SUBVOL_BACKUP_DIR/$SNAPSHOT_DIR" ]; then
    >&2 echo "$SUBVOL_BACKUP_DIR/$SNAPSHOT_DIR exists: maybe a previous operation was unsuccessful"
    return 1
  fi
  if [ -e "$SUBVOL_BACKUP_DIR/$SNAPSHOT_TMP_DIR" ]; then
    >&2 echo "$SUBVOL_BACKUP_DIR/$SNAPSHOT_TMP_DIR exists: maybe a previous operation was unsuccessful"
    return 1
  fi


  # Do the snapshot and backup
  if ! [ -e "$SNAPSHOT" ]; then
    # First time backup

    # Make the snapshot
    btrfs subvolume snapshot -r "$SUBVOL" "$SNAPSHOT"
    sync

    # Send the snapshot
    echo "Sending snapshot to backup: $SNAPSHOT -> $SUBVOL_BACKUP_DIR"
    (btrfs send "$SNAPSHOT" | btrfs receive "$SUBVOL_BACKUP_DIR")>/dev/null
    sync

    # Rename the snapshot
    mv "$SUBVOL_BACKUP_DIR/$SNAPSHOT_DIR" "$BACKUP_SNAPSHOT"
  else
    # Incremental backup

    # Make the snapshot
    btrfs subvolume snapshot -r "$SUBVOL" "$SNAPSHOT_TMP"
    sync

    # Compare the new snapshot to the last one, if no changes delete and exit
    if compare_dirs "$SNAPSHOT" "$SNAPSHOT_TMP"; then
      echo "No changes since last snapshot - skipping backup"
      btrfs subvolume delete "$SNAPSHOT_TMP"
      return
    fi

    # Send the snapshot
    echo "Sending snapshot to backup: $SNAPSHOT -> $SUBVOL_BACKUP_DIR"
    (btrfs send -p "$SNAPSHOT" "$SNAPSHOT_TMP" | btrfs receive "$SUBVOL_BACKUP_DIR") > /dev/null
    sync

    # Rename the snapshot
    mv "$SUBVOL_BACKUP_DIR/$SNAPSHOT_TMP_DIR" "$BACKUP_SNAPSHOT"

    # Delete old snapshot on source and move temp into place
    btrfs subvolume delete "$SNAPSHOT"
    mv "$SNAPSHOT_TMP" "$SNAPSHOT"
  fi
}

backup(){
  if [ $# -lt 1 ] || [ -z "$1" ]; then
    >&2 echo "backup requires one argument"
    return 1
  fi
  local subvol="$(readlink -f "$(readlink -f $1)/")"
  # Skip the SNAPSHOT_DIR and SNAPSHOT_TMP_DIR
  if [ "$(basename "$subvol")" == "$SNAPSHOT_DIR" ] || [ "$(basename "$subvol")" == "$SNAPSHOT_TMP_DIR" ]; then
    return
  fi
  # Skip any directories in BACKUP_EXCLUDE
  if contains_element "$subvol" "${BACKUP_EXCLUDE[@]}"; then
    echo "Skipping subvolume: $subvol"
    return
  fi

  backup_subvolume "$subvol"
  if $RECURSIVE; then
    for SUBVOL in $(get_subvolumes "$subvol"); do
      backup "$SUBVOL"
    done
  fi
}

RECURSIVE=false

while [ "${1:0:1}" == "-" ]; do
  case "$1" in
    -r|--recursive)
      RECURSIVE=true
      ;;
    -d|--dest|--destination)
      shift
      BACKUP_DIR="$1"
      ;;
    --date-format)
      shift
      BACKUP_DATE_FORMAT="$1"
      ;;
    --snapshot-dirname)
      shift
      SNAPSHOT_DIR=$1
      ;;
    --snapshot-temp-dirname)
      shift
      SNAPSHOT_TMP_DIR=$1
      ;;
    *)
      >&2 echo "Unknown option: $1"
      exit 1
      ;;
  esac
  shift
done

# Check the arguments
if [ $# -lt 1 ]; then
  >&2 echo "Specify the subvolume to backup"
  exit 1
fi

# Set defaults
SNAPSHOT_DIR="${SNAPSHOT_DIR:-.snapshot}"
SNAPSHOT_TMP_DIR="${SNAPSHOT_TMP_DIR:-${SNAPSHOT_DIR}-tmp}"

# Check for missing required variables
if [ -z "${BACKUP_DIR}" ]; then
  >&2 echo "No backup directory specifed by the `--destination` flag or `BACKUP_DIR` environment variable"
  exit 1
fi

# Sanitise variables
BACKUP_DIR="$(readlink -f "${BACKUP_DIR}")"

# Does the backup dir exist?
if ! [ -e "$BACKUP_DIR" ]; then
  >&2 "$BACKUP_DIR: Destination does not exist"
  exit 1
fi

# Set the date format
BACKUP_DATE_FORMAT="${BACKUP_DATE_FORMAT:-%Y%m%dT%H%M%SZ}"

# Run the command
for SUBVOLUME in "$@"; do
  backup $SUBVOLUME
done

sync
