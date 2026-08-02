#!/bin/sh
#
# Create an FTP user end-to-end, meant to run inside the vsftpd
# container: inserts a row into the MySQL/MariaDB users table (using
# the same MYSQL_* env vars vsftpd itself is configured with) and
# provisions the matching home directory under /home. If a directory
# for the username already exists (e.g. left over from a deleted
# account), asks before linking the new account to it - default is
# no, 15s timeout.
#
#   docker compose exec -it vsftpd add-ftp-user.sh -u alice

set -eu

usage() {
    echo "Usage: $0 -u|--username <name> [-p|--password <password>]" >&2
    echo "  -u, --username  FTP username to create" >&2
    echo "  -p, --password  Password (omit to be prompted, hidden input)" >&2
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

# Restrict to characters safe for both SQL and a path segment under
# /home - this also rules out any path-traversal via the username.
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
    printf "Password for %s: " "$username"
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

existing="$(mariadb_exec "SELECT COUNT(*) FROM \`$MYSQL_TABLE\` WHERE \`$MYSQL_USER_COLUMN\` = '$escaped_username'")"
if [ "$existing" != "0" ]; then
    echo "Error: user '$username' already exists in $MYSQL_TABLE" >&2
    exit 1
fi

homedir="/home/$username"

# No account exists yet, but a directory with this name already does -
# could be leftover from a deleted account, or provisioned by hand.
# Confirm before linking a new account to it rather than assuming.
if [ -d "$homedir" ]; then
    printf "Home directory %s already exists but has no account. Create '%s' and link it to this folder? [y/N] (15s timeout) " "$homedir" "$username"
    read -t 15 -r reply || reply=""
    case "$reply" in
        [Yy]*) ;;
        *)
            echo "Aborted: not creating '$username' against the existing directory (default is no)." >&2
            exit 1
            ;;
    esac
fi

# WHERE NOT EXISTS instead of a plain INSERT closes the race between
# the "existing" check above and this statement: two concurrent runs
# for the same username can now only have one of them actually insert.
affected="$(mariadb_exec "INSERT INTO \`$MYSQL_TABLE\` (\`$MYSQL_USER_COLUMN\`, \`$MYSQL_PASSWD_COLUMN\`) SELECT '$escaped_username', '$escaped_hash' FROM DUAL WHERE NOT EXISTS (SELECT 1 FROM \`$MYSQL_TABLE\` WHERE \`$MYSQL_USER_COLUMN\` = '$escaped_username'); SELECT ROW_COUNT()")"
if [ "$affected" != "1" ]; then
    echo "Error: user '$username' already exists in $MYSQL_TABLE" >&2
    exit 1
fi

mkdir -p "$homedir"
chown vsftp:vsftp "$homedir"

echo "Created FTP user '$username' (row in $MYSQL_TABLE, home $homedir)"
