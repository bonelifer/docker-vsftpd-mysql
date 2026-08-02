FROM alpine:3.24.1 AS build
RUN apk update && apk add --no-cache \
        autoconf \
        automake \
        curl \
        gawk \
        gcc \
        gzip \
        libtool \
        linux-pam-dev \
        m4 \
        make \
        mariadb-dev \
        musl-dev \
        pkgconfig \
        tar
RUN curl -fL https://github.com/NigelCunningham/pam-MySQL/archive/v0.8.1.tar.gz -o /root/pam-mysql.tar.gz \
    && mkdir -p /root/pam-mysql \
    && tar xf /root/pam-mysql.tar.gz -C /root/pam-mysql --strip-components 1
RUN cd /root/pam-mysql \
    && autoreconf -i \
    && ./configure \
    && make install \
    && strip /usr/lib/security/pam_mysql.so

FROM golang:1.26.5-alpine3.24 AS golang
RUN apk update && apk add --no-cache binutils git
RUN go install github.com/drone/envsubst/cmd/envsubst@v1.0.3 \
    && strip /go/bin/envsubst

FROM alpine:3.24.1
RUN apk add --no-cache linux-pam mariadb-client mariadb-connector-c nano openssl tzdata vsftpd

ENV TZ=America/Chicago \
    LISTEN_PORT=21 \
    PASV_ENABLE=YES \
    PASV_MAX_PORT=0 \
    PASV_MIN_PORT=0

COPY --from=build /usr/lib/security/pam_mysql.so /usr/lib/security/pam_mysql.so
COPY --from=golang /go/bin/envsubst /bin/envsubst
COPY vsftpd.sh /usr/sbin/
COPY add-ftp-user.sh delete-ftp-user.sh check-ftp-user-dirs.sh check-ftp-orphan-dirs.sh /usr/local/sbin/
COPY vsftpd.conf.tpl vsftpd.mysql.tpl /config/

CMD ["/usr/sbin/vsftpd.sh"]
