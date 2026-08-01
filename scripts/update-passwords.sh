#!/usr/bin/bash
#
# Generate new random MYSQL/MARIADB passwords, write them into
# docker-compose.yml, and print them to the terminal so the user can
# record them somewhere safe.

set -e

usage() {
    echo "Usage: $0 [-f|--file <docker-compose.yml>] [-l|--length <bytes>]" >&2
    echo "  -f, --file    Path to the compose file to update (default: docker-compose.yml)" >&2
    echo "  -l, --length  Random bytes to generate per password before encoding (default: 24)" >&2
    echo "  -h, --help    Show this help" >&2
}

compose_file="docker-compose.yml"
pass_len=24

while [ "$#" -gt 0 ]; do
    case "$1" in
        -f|--file)
            compose_file="$2"
            shift 2
            ;;
        -l|--length)
            pass_len="$2"
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

if [ ! -f "$compose_file" ]; then
    echo "Error: compose file not found: $compose_file" >&2
    exit 1
fi

# Alphanumeric only: safe to drop straight into an unquoted YAML scalar
# with no risk of '#', ':', or '/' being misparsed.
generate_password() {
    openssl rand -base64 "$pass_len" | tr -dc 'A-Za-z0-9'
}

db_password="$(generate_password)"
root_password="$(generate_password)"

backup_file="${compose_file}.bak"
cp "$compose_file" "$backup_file"

# MYSQL_PASSWORD (vsftpd service) and MARIADB_PASSWORD (mariadb service)
# must match - they're the same database account.
sed -i \
    -e "s/^\([[:space:]]*-[[:space:]]*MYSQL_PASSWORD=\).*/\1${db_password}/" \
    -e "s/^\([[:space:]]*-[[:space:]]*MARIADB_PASSWORD=\).*/\1${db_password}/" \
    -e "s/^\([[:space:]]*-[[:space:]]*MARIADB_ROOT_PASSWORD=\).*/\1${root_password}/" \
    "$compose_file"

echo "Updated ${compose_file} (previous version backed up to ${backup_file})"
echo
echo "New credentials - save these now, they are not stored anywhere else:"
echo "  MYSQL_PASSWORD / MARIADB_PASSWORD : ${db_password}"
echo "  MARIADB_ROOT_PASSWORD             : ${root_password}"
echo
echo "Run 'docker compose up -d' to apply them."
