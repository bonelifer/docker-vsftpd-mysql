#!/bin/sh
#
# Delete an FTP user, meant to run inside the vsftpd container: removes
# the matching row from the MySQL/MariaDB users table (using the same
# MYSQL_* env vars vsftpd itself is configured with). The home
# directory under /home is left alone by default; use --delete-dir or
# --keep-dir to skip the interactive prompt. Refuses to delete a
# directory that isn't vsftp-owned unless --force is given.
#
#   docker compose exec -it vsftpd delete-ftp-user.sh -u alice

set -eu

usage() {
    echo "Usage: $0 -u|--username <name> [--delete-dir|--keep-dir] [--force]" >&2
    echo "  -u, --username  FTP username to delete" >&2
    echo "      --delete-dir  Delete /home/<username> too, no prompt" >&2
    echo "      --keep-dir    Keep /home/<username>, no prompt" >&2
    echo "      --force       Delete the directory even if it's not vsftp-owned" >&2
    echo "  -h, --help      Show this help" >&2
}

username=""
dir_action=""
force=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        -u|--username)
            username="$2"
            shift 2
            ;;
        --delete-dir)
            dir_action="delete"
            shift
            ;;
        --keep-dir)
            dir_action="keep"
            shift
            ;;
        --force)
            force=1
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

if [ -z "$username" ]; then
    echo "Error: --username is required" >&2
    usage
    exit 1
fi

# Same restriction as add-ftp-user.sh: safe for both SQL and a path
# segment under /home, and rules out path traversal.
case "$username" in
    *[!A-Za-z0-9_-]*)
        echo "Error: username must contain only letters, digits, '_' and '-'" >&2
        exit 1
        ;;
esac

: "${MYSQL_HOST:?MYSQL_HOST is not set}"
: "${MYSQL_USER:?MYSQL_USER is not set}"
: "${MYSQL_PASSWORD:?MYSQL_PASSWORD is not set}"
: "${MYSQL_DATABASE:?MYSQL_DATABASE is not set}"
: "${MYSQL_TABLE:?MYSQL_TABLE is not set}"
: "${MYSQL_USER_COLUMN:?MYSQL_USER_COLUMN is not set}"

# Escapes a value for use inside a single-quoted SQL string literal.
sql_escape() {
    printf '%s' "$1" | sed "s/\\\\/\\\\\\\\/g; s/'/\\\\'/g"
}

mariadb_exec() {
    MYSQL_PWD="$MYSQL_PASSWORD" mariadb -N -B \
        -h "$MYSQL_HOST" -u "$MYSQL_USER" "$MYSQL_DATABASE" -e "$1"
}

escaped_username="$(sql_escape "$username")"

existing="$(mariadb_exec "SELECT COUNT(*) FROM \`$MYSQL_TABLE\` WHERE \`$MYSQL_USER_COLUMN\` = '$escaped_username'")"
if [ "$existing" = "0" ]; then
    echo "Error: user '$username' not found in $MYSQL_TABLE" >&2
    exit 1
fi

mariadb_exec "DELETE FROM \`$MYSQL_TABLE\` WHERE \`$MYSQL_USER_COLUMN\` = '$escaped_username'"
echo "Deleted user '$username' from $MYSQL_TABLE"

homedir="/home/$username"

if [ -z "$dir_action" ]; then
    if [ -t 0 ]; then
        printf "Also delete home directory %s? [y/N] " "$homedir"
        read -r reply
        case "$reply" in
            [Yy]*) dir_action="delete" ;;
            *) dir_action="keep" ;;
        esac
    else
        echo "No TTY for a prompt; keeping $homedir (pass --delete-dir to remove it non-interactively)" >&2
        dir_action="keep"
    fi
fi

if [ "$dir_action" = "delete" ]; then
    if [ -d "$homedir" ]; then
        # Refuse to rm -rf a directory that isn't actually vsftp's,
        # in case the username matched something unrelated by
        # accident. --force overrides this.
        dir_uid="$(stat -c %u "$homedir")"
        dir_gid="$(stat -c %g "$homedir")"
        vsftp_uid="$(id -u vsftp)"
        vsftp_gid="$(id -g vsftp)"
        if { [ "$dir_uid" != "$vsftp_uid" ] || [ "$dir_gid" != "$vsftp_gid" ]; } && [ "$force" != "1" ]; then
            echo "Error: refusing to delete $homedir, it is not owned by vsftp (use --force to override)" >&2
            exit 1
        fi
        rm -rf -- "$homedir"
        echo "Deleted $homedir"
    else
        echo "$homedir does not exist, nothing to delete"
    fi
else
    echo "Left $homedir in place"
fi
