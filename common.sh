# Define some functions
contains_element() {
  local e
  for e in "${@:2}"; do [[ "$e" == "$1" ]] && return 0; done
  return 1
}

require_root(){
  if [ "$EUID" -ne 0 ]; then
    >&2 echo "Must be run as root"
    exit
  fi
}

is_subvolume(){
  if [ $# -lt 1 ] || [ -z "$1" ]; then
    >&2 echo "is_subvolume requires one argument"
    return 1
  fi
  btrfs subvolume show "$1" >/dev/null 2>&1
  return $?
}

get_subvolumes(){
  if [ $# -lt 1 ] || [ -z "$1" ]; then
    >&2 echo "get_subvolumes requires one argument"
    return 1
  fi
  local subvol="$(readlink -f "$1")/"
  local subvol_name="$(btrfs subvolume show "$subvol" | awk '/^[[:space:]]*Name:/ {print $2}')"
  # TODO: This is not perfect, need to get full path and strip that.
  if [ -z "$subvol_name" ]; then
    btrfs subvolume list --sort=path -o "$subvol" | cut -d' ' -f9  | nl -s "$subvol" | cut -c7- | xargs readlink -f
  else
    subvol_name="$(echo "$subvol_name" | sed -e 's/[]\/$*.^|[]/\\&/g')"
    btrfs subvolume list --sort=path -o "$subvol" | cut -d' ' -f9 | sed "s/^.*${subvol_name}\///" | nl -s "$subvol" | cut -c7- | xargs readlink -f
  fi
}

prepare_backup_dir(){
  if [ $# -lt 1 ] || [ -z "$1" ]; then
    >&2 echo "prepare_backup_dir requires one argument"
    return 1
  fi
  local DIR="$(readlink -f "$1")"
  if [ -e "${BACKUP_DIR}${DIR}" ]; then
    # Directory exists, nothing to do
    return
  elif [ "${DIR}" == "/" ]; then
    # Directory is root, but doesn't exist? Nothing we can do, fail!
    >&2 "$BACKUP_DIR: BACKUP_DIR does not exist"
    return 1
  fi
  # Recursively create the parent directory
  prepare_backup_dir "$(dirname "$DIR")" || return 1
  # Match source structure (subvol or directory
  if is_subvolume "$DIR"; then
    # Source is a subvolume, create a subvolume
    btrfs subvolume create "${BACKUP_DIR}${DIR}"
  else
    # Source is a directory, creare a directory
    mkdir "${BACKUP_DIR}${DIR}"
  fi
}

compare_dirs(){
  if [ $# -lt 2 ] || [ -z "$1" ] || [ -z "$2" ]; then
    >&2 echo "compare_dirs takes two argument"
    return 1
  fi
  # If the directory contents is the same and they have the same MD5 then return 0, otherwise they are different
  if diff <(cd "$1"; find) <(cd "$2"; find) > /dev/null && [ "$(md5sum_dir "$1")" = "$(md5sum_dir "$2")" ]; then
    return 0
  else
    return 1
  fi
}

md5sum_dir(){
  if [ $# -lt 1 ] || [ -z "$1" ]; then
    >&2 echo "md5sum_dir requires one argument"
    return 1
  fi
  (cd "$1"; find -type f -exec md5sum {} +; find -type d) | LC_ALL=C sort | md5sum
}
