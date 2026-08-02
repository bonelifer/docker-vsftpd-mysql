#!/bin/sh
#
# Change an existing FTP user's password, meant to run inside the
# vsftpd container: updates the matching row in the MySQL/MariaDB
# users table (using the same MYSQL_* env vars vsftpd itself is
# configured with). Doesn't touch the home directory.
#
#   docker compose exec -it vsftpd set-ftp-password.sh -u alice

set -eu

usage() {
    echo "Usage: $0 -u|--username <name> [-p|--password <password>]" >&2
    echo "  -u, --username  FTP username to update" >&2
    echo "  -p, --password  New password (omit to be prompted, hidden input)" >&2
    echo "  -h, --help      Show this help" >&2
}

username=""
password=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        -u|--username)
            username="$2"
            shift 2
            ;;
        -p|--password)
            password="$2"
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

if [ -z "$username" ]; then
    echo "Error: --username is required" >&2
    usage
    exit 1
fi

# Same restriction as add-ftp-user.sh: safe for both SQL and a path
# segment under /home.
case "$username" in
    *[!A-Za-z0-9_-]*)
        echo "Error: username must contain only letters, digits, '_' and '-'" >&2
        exit 1
        ;;
esac

if [ -z "$password" ]; then
    if [ ! -t 0 ]; then
        echo "Error: no TTY for a password prompt; pass --password or run with 'docker compose exec -it'" >&2
        exit 1
    fi
    printf "New password for %s: " "$username"
    stty -echo
    read -r password
    stty echo
    printf "\n"
    printf "Confirm password: "
    stty -echo
    read -r password_confirm
    stty echo
    printf "\n"
    if [ "$password" != "$password_confirm" ]; then
        echo "Error: passwords do not match" >&2
        exit 1
    fi
fi

if [ -z "$password" ]; then
    echo "Error: password must not be empty" >&2
    exit 1
fi

: "${MYSQL_HOST:?MYSQL_HOST is not set}"
: "${MYSQL_USER:?MYSQL_USER is not set}"
: "${MYSQL_PASSWORD:?MYSQL_PASSWORD is not set}"
: "${MYSQL_DATABASE:?MYSQL_DATABASE is not set}"
: "${MYSQL_TABLE:?MYSQL_TABLE is not set}"
: "${MYSQL_USER_COLUMN:?MYSQL_USER_COLUMN is not set}"
: "${MYSQL_PASSWD_COLUMN:?MYSQL_PASSWD_COLUMN is not set}"
crypt_mode="${MYSQL_PASSWD_CRYPT:-1}"

# Escapes a value for use inside a single-quoted SQL string literal.
sql_escape() {
    printf '%s' "$1" | sed "s/\\\\/\\\\\\\\/g; s/'/\\\\'/g"
}

mariadb_exec() {
    MYSQL_PWD="$MYSQL_PASSWORD" mariadb -N -B \
        -h "$MYSQL_HOST" -u "$MYSQL_USER" "$MYSQL_DATABASE" -e "$1"
}

case "$crypt_mode" in
    1)
        password_hash="$(openssl passwd -6 "$password")"
        ;;
    2)
        password_hash="$(mariadb_exec "SELECT PASSWORD('$(sql_escape "$password")')")"
        ;;
    0)
        password_hash="$password"
        echo "Warning: MYSQL_PASSWD_CRYPT=0 stores this password in plaintext." >&2
        ;;
    *)
        echo "Error: unsupported MYSQL_PASSWD_CRYPT value: $crypt_mode" >&2
        exit 1
        ;;
esac

escaped_username="$(sql_escape "$username")"
escaped_hash="$(sql_escape "$password_hash")"

# Existence is checked separately rather than via UPDATE's ROW_COUNT():
# ROW_COUNT() reflects rows *changed*, not rows *matched* - setting a
# password that happens to hash identically to the one already stored
# would report 0 even though the user exists.
existing="$(mariadb_exec "SELECT COUNT(*) FROM \`$MYSQL_TABLE\` WHERE \`$MYSQL_USER_COLUMN\` = '$escaped_username'")"
if [ "$existing" = "0" ]; then
    echo "Error: user '$username' not found in $MYSQL_TABLE" >&2
    exit 1
fi

mariadb_exec "UPDATE \`$MYSQL_TABLE\` SET \`$MYSQL_PASSWD_COLUMN\` = '$escaped_hash' WHERE \`$MYSQL_USER_COLUMN\` = '$escaped_username'"

echo "Updated password for '$username' in $MYSQL_TABLE"
