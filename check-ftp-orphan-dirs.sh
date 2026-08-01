#!/bin/sh
#
# Audit /home for directories with no matching row in the users
# table - the reverse of check-ftp-user-dirs.sh. Meant to run inside
# the vsftpd container, using the same MYSQL_* env vars vsftpd itself
# is configured with.
#
#   docker compose exec vsftpd check-ftp-orphan-dirs.sh
#
# Exits 0 if every directory under /home has a matching row, 1 if
# any don't.

set -eu

usage() {
    echo "Usage: $0 [-d|--dir <path>]" >&2
    echo "  -d, --dir   Directory to scan for FTP home directories (default: /home)" >&2
    echo "  -h, --help  Show this help" >&2
}

home_dir="/home"

while [ "$#" -gt 0 ]; do
    case "$1" in
        -d|--dir)
            home_dir="$2"
            shift 2
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

    if [ ! -d "$entry" ]; then
        echo "NOTDIR   $name ($entry is not a directory)"
        total=$((total + 1))
        bad=$((bad + 1))
        continue
    fi

    total=$((total + 1))

    escaped_name="$(sql_escape "$name")"
    count="$(mariadb_exec "SELECT COUNT(*) FROM \`$MYSQL_TABLE\` WHERE \`$MYSQL_USER_COLUMN\` = '$escaped_name'")"

    if [ "$count" = "0" ]; then
        echo "ORPHAN   $name ($entry has no matching row in $MYSQL_TABLE)"
        bad=$((bad + 1))
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
