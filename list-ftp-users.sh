#!/bin/sh
#
# List every FTP username in the users table, meant to run inside the
# vsftpd container, using the same MYSQL_* env vars vsftpd itself is
# configured with. Never prints password hashes.
#
#   docker compose exec vsftpd list-ftp-users.sh

set -eu

usage() {
    echo "Usage: $0" >&2
    echo "  -h, --help  Show this help" >&2
}

while [ "$#" -gt 0 ]; do
    case "$1" in
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

mariadb_exec() {
    MYSQL_PWD="$MYSQL_PASSWORD" mariadb -N -B \
        -h "$MYSQL_HOST" -u "$MYSQL_USER" "$MYSQL_DATABASE" -e "$1"
}

usernames="$(mariadb_exec "SELECT \`$MYSQL_USER_COLUMN\` FROM \`$MYSQL_TABLE\` ORDER BY \`$MYSQL_USER_COLUMN\`")"

if [ -z "$usernames" ]; then
    echo "No rows in $MYSQL_TABLE."
    exit 0
fi

total=0
old_ifs="$IFS"
IFS='
'
set -f
for name in $usernames; do
    total=$((total + 1))
    echo "$name"
done
set +f
IFS="$old_ifs"

echo
echo "$total user(s) in $MYSQL_TABLE."
