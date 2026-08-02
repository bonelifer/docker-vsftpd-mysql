#!/bin/sh
#
# Audit /home for directories with no matching row in the users
# table - the reverse of check-ftp-user-dirs.sh. Meant to run inside
# the vsftpd container, using the same MYSQL_* env vars vsftpd itself
# is configured with. --fix offers to delete orphans/stray files -
# unlike check-ftp-user-dirs.sh's --fix, this is destructive, so it
# asks per item (default no, 15s timeout) even with --fix given.
#
#   docker compose exec vsftpd check-ftp-orphan-dirs.sh
#   docker compose exec -it vsftpd check-ftp-orphan-dirs.sh --fix
#
# Exits 0 if every directory under /home has a matching row, 1 if
# any don't.

set -eu

usage() {
    echo "Usage: $0 [-d|--dir <path>] [--fix]" >&2
    echo "  -d, --dir   Directory to scan for FTP home directories (default: /home)" >&2
    echo "      --fix   Offer to delete orphans/stray files (asks per item)" >&2
    echo "  -h, --help  Show this help" >&2
}

home_dir="/home"
fix=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        -d|--dir)
            home_dir="$2"
            shift 2
            ;;
        --fix)
            fix=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage
            exit 1
            ;;
    esac
done

: "${MYSQL_HOST:?MYSQL_HOST is not set}"
: "${MYSQL_USER:?MYSQL_USER is not set}"
: "${MYSQL_PASSWORD:?MYSQL_PASSWORD is not set}"
: "${MYSQL_DATABASE:?MYSQL_DATABASE is not set}"
: "${MYSQL_TABLE:?MYSQL_TABLE is not set}"
: "${MYSQL_USER_COLUMN:?MYSQL_USER_COLUMN is not set}"

if [ ! -d "$home_dir" ]; then
    echo "Error: directory not found: $home_dir" >&2
    exit 1
fi

# Escapes a value for use inside a single-quoted SQL string literal.
sql_escape() {
    printf '%s' "$1" | sed "s/\\\\/\\\\\\\\/g; s/'/\\\\'/g"
}

mariadb_exec() {
    MYSQL_PWD="$MYSQL_PASSWORD" mariadb -N -B \
        -h "$MYSQL_HOST" -u "$MYSQL_USER" "$MYSQL_DATABASE" -e "$1"
}

confirm_delete() {
    printf "Delete %s? [y/N] (15s timeout) " "$1"
    read -t 15 -r reply || reply=""
    case "$reply" in
        [Yy]*) return 0 ;;
        *) return 1 ;;
    esac
}

total=0
bad=0

for entry in "$home_dir"/*; do
    [ -e "$entry" ] || continue

    name="$(basename "$entry")"

    case "$name" in
        .*|lost+found)
            continue
            ;;
    esac

    total=$((total + 1))

    if [ ! -d "$entry" ]; then
        if [ "$fix" = "1" ] && confirm_delete "$entry"; then
            rm -f -- "$entry"
            echo "FIXED    $name ($entry was not a directory, deleted)"
        else
            echo "NOTDIR   $name ($entry is not a directory)"
            bad=$((bad + 1))
        fi
        continue
    fi

    escaped_name="$(sql_escape "$name")"
    count="$(mariadb_exec "SELECT COUNT(*) FROM \`$MYSQL_TABLE\` WHERE \`$MYSQL_USER_COLUMN\` = '$escaped_name'")"

    if [ "$count" = "0" ]; then
        if [ "$fix" = "1" ] && confirm_delete "$entry"; then
            rm -rf -- "$entry"
            echo "FIXED    $name ($entry had no matching row, deleted)"
        else
            echo "ORPHAN   $name ($entry has no matching row in $MYSQL_TABLE)"
            bad=$((bad + 1))
        fi
        continue
    fi

    echo "OK       $name"
done

if [ "$total" -eq 0 ]; then
    echo "No directories under $home_dir."
    exit 0
fi

echo
echo "$((total - bad))/$total directories have a matching users row."

[ "$bad" -eq 0 ]
