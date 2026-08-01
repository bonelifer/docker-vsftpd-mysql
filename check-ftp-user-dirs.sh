#!/bin/sh
#
# Audit the users table for rows with no valid home directory under
# /home: missing entirely, present but not owned by vsftp (which
# breaks uploads/chroot for that user), or an unsafe username that
# add-ftp-user.sh would never have created. Meant to run inside the
# vsftpd container, using the same MYSQL_* env vars vsftpd itself is
# configured with.
#
#   docker compose exec vsftpd check-ftp-user-dirs.sh
#
# Exits 0 if every row has a valid home directory, 1 if any don't.

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

vsftp_uid="$(id -u vsftp)"
vsftp_gid="$(id -g vsftp)"

usernames="$(mariadb_exec "SELECT \`$MYSQL_USER_COLUMN\` FROM \`$MYSQL_TABLE\`")"

if [ -z "$usernames" ]; then
    echo "No rows in $MYSQL_TABLE."
    exit 0
fi

total=0
bad=0

old_ifs="$IFS"
IFS='
'
set -f
for name in $usernames; do
    total=$((total + 1))

    case "$name" in
        *[!A-Za-z0-9_-]*|"")
            echo "INVALID  $name (unsafe/empty username, can't have a managed home directory)"
            bad=$((bad + 1))
            continue
            ;;
    esac

    homedir="/home/$name"

    if [ ! -d "$homedir" ]; then
        echo "MISSING  $name ($homedir does not exist)"
        bad=$((bad + 1))
        continue
    fi

    dir_uid="$(stat -c %u "$homedir")"
    dir_gid="$(stat -c %g "$homedir")"
    if [ "$dir_uid" != "$vsftp_uid" ] || [ "$dir_gid" != "$vsftp_gid" ]; then
        echo "BADOWNER $name ($homedir exists but is not owned by vsftp)"
        bad=$((bad + 1))
        continue
    fi

    echo "OK       $name"
done
set +f
IFS="$old_ifs"

echo
echo "$((total - bad))/$total users have a valid home directory."

[ "$bad" -eq 0 ]
