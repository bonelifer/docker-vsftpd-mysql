#!/bin/sh
#
# Rename an existing FTP user, meant to run inside the vsftpd
# container: updates the matching row in the MySQL/MariaDB users
# table and moves /home/<old> to /home/<new> (using the same MYSQL_*
# env vars vsftpd itself is configured with). Refuses to run if
# /home/<new> already exists, rather than risk merging its contents
# with the renamed user's data - resolve that manually first.
#
#   docker compose exec vsftpd rename-ftp-user.sh -o alice -n alicia

set -eu

usage() {
    echo "Usage: $0 -o|--old-username <name> -n|--new-username <name>" >&2
    echo "  -o, --old-username  Current FTP username" >&2
    echo "  -n, --new-username  New FTP username" >&2
    echo "  -h, --help          Show this help" >&2
}

old_username=""
new_username=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        -o|--old-username)
            old_username="$2"
            shift 2
            ;;
        -n|--new-username)
            new_username="$2"
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

if [ -z "$old_username" ] || [ -z "$new_username" ]; then
    echo "Error: both --old-username and --new-username are required" >&2
    usage
    exit 1
fi

if [ "$old_username" = "$new_username" ]; then
    echo "Error: --new-username must be different from --old-username" >&2
    exit 1
fi

# Same restriction as add-ftp-user.sh: safe for both SQL and a path
# segment under /home, and rules out path traversal.
for name in "$old_username" "$new_username"; do
    case "$name" in
        *[!A-Za-z0-9_-]*)
            echo "Error: usernames must contain only letters, digits, '_' and '-'" >&2
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

# Escapes a value for use inside a single-quoted SQL string literal.
sql_escape() {
    printf '%s' "$1" | sed "s/\\\\/\\\\\\\\/g; s/'/\\\\'/g"
}

mariadb_exec() {
    MYSQL_PWD="$MYSQL_PASSWORD" mariadb -N -B \
        -h "$MYSQL_HOST" -u "$MYSQL_USER" "$MYSQL_DATABASE" -e "$1"
}

escaped_old="$(sql_escape "$old_username")"
escaped_new="$(sql_escape "$new_username")"

# Check the new username against the actual column width rather than
# assuming one. The old username doesn't need this check - it's
# already a row in the table, so it already fits.
max_len="$(mariadb_exec "SELECT CHARACTER_MAXIMUM_LENGTH FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = '$(sql_escape "$MYSQL_TABLE")' AND COLUMN_NAME = '$(sql_escape "$MYSQL_USER_COLUMN")'")"
if [ -n "$max_len" ] && [ "$max_len" != "NULL" ] && [ "${#new_username}" -gt "$max_len" ]; then
    echo "Error: username '$new_username' is ${#new_username} characters, longer than $MYSQL_TABLE.$MYSQL_USER_COLUMN's limit of $max_len" >&2
    exit 1
fi

existing_old="$(mariadb_exec "SELECT COUNT(*) FROM \`$MYSQL_TABLE\` WHERE \`$MYSQL_USER_COLUMN\` = '$escaped_old'")"
if [ "$existing_old" = "0" ]; then
    echo "Error: user '$old_username' not found in $MYSQL_TABLE" >&2
    exit 1
fi

# AND usercol <> old (not just != in shell) matters here: MySQL/MariaDB's
# default collation is case-insensitive, so a case-only rename (alice ->
# Alice) would otherwise match its own row and falsely report a conflict.
# <> is subject to the same collation as =, so it correctly excludes the
# row being renamed while still catching a real different user.
existing_new="$(mariadb_exec "SELECT COUNT(*) FROM \`$MYSQL_TABLE\` WHERE \`$MYSQL_USER_COLUMN\` = '$escaped_new' AND \`$MYSQL_USER_COLUMN\` <> '$escaped_old'")"
if [ "$existing_new" != "0" ]; then
    echo "Error: user '$new_username' already exists in $MYSQL_TABLE" >&2
    exit 1
fi

old_homedir="/home/$old_username"
new_homedir="/home/$new_username"

# A plain `mv` onto an existing directory moves the source *into* it
# as a subdirectory instead of renaming it - silently not what we
# want. Refuse rather than risk mixing the two users' files.
if [ -e "$new_homedir" ]; then
    echo "Error: $new_homedir already exists; resolve that manually before renaming into it" >&2
    exit 1
fi

mariadb_exec "UPDATE \`$MYSQL_TABLE\` SET \`$MYSQL_USER_COLUMN\` = '$escaped_new' WHERE \`$MYSQL_USER_COLUMN\` = '$escaped_old'"

if [ -d "$old_homedir" ]; then
    mv -- "$old_homedir" "$new_homedir"
else
    mkdir -p "$new_homedir"
    chown vsftp:vsftp "$new_homedir"
    echo "Note: $old_homedir did not exist; created $new_homedir fresh." >&2
fi

echo "Renamed FTP user '$old_username' to '$new_username' (row in $MYSQL_TABLE, home $new_homedir)"
