# docker-vsftpd-mysql

vsftpd with MySQL-backed authentication (via [pam-MySQL](https://github.com/NigelCunningham/pam-MySQL)), built on Alpine.

## Limits

- User home directories must be created manually. [pam-MySQL](https://github.com/NigelCunningham/pam-MySQL) does not support `getpwnam`, so vsftpd can't resolve a home directory from the system's user database — it relies on `local_root=/home/$USER` in `vsftpd.conf.tpl` instead.

## Build

```sh
docker build -t docker-vsftpd-mysql .
```

Images built from `master` and version tags (`vN.N.N`) are also published automatically to `ghcr.io/bonelifer/docker-vsftpd-mysql` by [`.github/workflows/build.yml`](.github/workflows/build.yml).

## Configuration

| Variable | Default | Description |
|---|---|---|
| `MYSQL_USER` | — | MySQL user used to run the auth query |
| `MYSQL_PASSWORD` | — | Password for `MYSQL_USER` |
| `MYSQL_HOST` | — | MySQL host |
| `MYSQL_DATABASE` | — | Database containing the FTP users table |
| `MYSQL_TABLE` | — | Table containing FTP user credentials |
| `MYSQL_USER_COLUMN` | — | Column holding the FTP username |
| `MYSQL_PASSWD_COLUMN` | — | Column holding the (hashed) FTP password |
| `MYSQL_PASSWD_CRYPT` | `1` | Password hashing mode used by pam-MySQL: `0` = plaintext (**do not use**), `1` = `crypt(3)` (recommended), `2` = MySQL `PASSWORD()`. See [pam-MySQL's README](https://github.com/NigelCunningham/pam-MySQL#readme) for details. |
| `LISTEN_PORT` | `21` | FTP control port |
| `PASV_ENABLE` | `YES` | Enable passive mode |
| `PASV_ADDRESS` | (empty) | Public IP advertised to clients for passive connections |
| `PASV_MIN_PORT` | `0` | Passive port range start (`0` lets the OS choose) |
| `PASV_MAX_PORT` | `0` | Passive port range end |

With `MYSQL_PASSWD_CRYPT=1`, store passwords hashed with `crypt(3)`, e.g.:

```sh
openssl passwd -6 'yourpassword'
```

## Deploy

[`docker-compose.yml`](docker-compose.yml) brings up `vsftpd` alongside a `mariadb` service seeded with a test user (see [Quick start](#quick-start) below):

```yaml
services:
  vsftpd-init:
    image: ghcr.io/bonelifer/docker-vsftpd-mysql:latest
    container_name: vsftpd-init
    entrypoint: ["/bin/sh", "-c", "mkdir -p /home/testuser && chown vsftp:vsftp /home/testuser"]
    volumes:
      - /var/ftp:/home
    restart: "no"

  vsftpd:
    image: ghcr.io/bonelifer/docker-vsftpd-mysql:latest
    container_name: vsftpd
    restart: always
    network_mode: "host"
    depends_on:
      mariadb:
        condition: service_started
      vsftpd-init:
        condition: service_completed_successfully
    environment:
      - MYSQL_USER=user
      - MYSQL_PASSWORD=password
      - MYSQL_HOST=127.0.0.1
      - MYSQL_DATABASE=database
      - MYSQL_TABLE=users
      - MYSQL_USER_COLUMN=name
      - MYSQL_PASSWD_COLUMN=password
      - MYSQL_PASSWD_CRYPT=1
      - LISTEN_PORT=21
      - PASV_ENABLE=YES
      - PASV_ADDRESS=
      - PASV_MIN_PORT=0
      - PASV_MAX_PORT=0
    volumes:
      - /var/ftp:/home

  mariadb:
    image: mariadb:11.4.12
    container_name: vsftpd-mariadb
    restart: always
    ports:
      - "127.0.0.1:3306:3306"
    environment:
      # Change this for anything beyond local testing.
      - MARIADB_ROOT_PASSWORD=changeme
      - MARIADB_DATABASE=database
      - MARIADB_USER=user
      - MARIADB_PASSWORD=password
    volumes:
      - mariadb-data:/var/lib/mysql
      - ./mariadb-init:/docker-entrypoint-initdb.d:ro

volumes:
  mariadb-data:
```

`MARIADB_DATABASE`/`MARIADB_USER`/`MARIADB_PASSWORD` on the `mariadb` service must match `MYSQL_DATABASE`/`MYSQL_USER`/`MYSQL_PASSWORD` on the `vsftpd` service — they're the same credentials, just named per each image's convention.

The bundled `mariadb` service is meant for trying this out locally. If you already run MySQL/MariaDB elsewhere, drop that service and point `MYSQL_HOST` at it instead.

### Networking

`network_mode: "host"` is used above so passive-mode data connections don't need an explicit published port range. If you'd rather keep the container on an isolated Docker network, set `PASV_MIN_PORT`/`PASV_MAX_PORT` to a fixed range and publish `LISTEN_PORT` plus that range with `ports:` instead of using host networking. `mariadb`'s port is published to `127.0.0.1` only, since `vsftpd` (on host networking) reaches it via `MYSQL_HOST=127.0.0.1`.

### Quick start

[`mariadb-init/001-create-users.sql`](mariadb-init/001-create-users.sql) seeds a `users` table with one test login: `testuser` / `testpass` (stored as a `crypt(3)` SHA-512 hash). The `vsftpd-init` service creates and `chown`s that user's home directory automatically before `vsftpd` starts.

```sh
docker compose up -d
ftp 127.0.0.1
# login as testuser / testpass
```

Per [Limits](#limits) above, pam-MySQL can't create home directories for arbitrary FTP users — `vsftpd-init` only provisions the bundled `testuser`. Any other user you add to the `users` table still needs its home directory created (and owned by `vsftp`) the same way, e.g. by extending `vsftpd-init`'s command or running it manually against the `/var/ftp` volume.

## Contributing

Contributions are welcome!

- **Bug reports**: [Open an issue](https://github.com/bonelifer/docker-vsftpd-mysql/issues).
- **Everything else** (questions, feature requests, ideas, general discussion): [Use Discussions](https://github.com/bonelifer/docker-vsftpd-mysql/discussions).
- Pull requests are welcome for bug fixes or discussed features.

## Acknowledgments

- Originally forked from [cuckoohello/docker-vsftpd-mysql](https://github.com/cuckoohello/docker-vsftpd-mysql).
- Code review, bug fixes, and documentation assisted by [Claude](https://www.anthropic.com/claude).

## License

This project is licensed under the **GNU General Public License v3.0**.

See [LICENSE](LICENSE) for more information.
