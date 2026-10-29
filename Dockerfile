# Build
FROM alpine:3.24 AS build

RUN apk add --no-cache curl ca-certificates gnupg

WORKDIR /tmp/easyrsa

ARG EASYRSA_VERSION="3.2.7"

RUN curl -fsSL -o easyrsa.tar.gz "https://github.com/OpenVPN/easy-rsa/releases/download/v${EASYRSA_VERSION}/EasyRSA-${EASYRSA_VERSION}.tgz"
RUN curl -fsSL -o easyrsa.tar.gz.sig "https://github.com/OpenVPN/easy-rsa/releases/download/v${EASYRSA_VERSION}/EasyRSA-${EASYRSA_VERSION}.tgz.sig"

RUN curl -fsSL --connect-timeout 10 \
    "https://keys.openpgp.org/vks/v1/by-fingerprint/6F4056821152F03B6B24F2FCF8489F839D7367F3" \
    | gpg --import && \
    gpg --batch --verify easyrsa.tar.gz.sig easyrsa.tar.gz

RUN tar -xzf easyrsa.tar.gz --strip-components=1 && \
    chmod 0550 easyrsa

# Runtime
FROM alpine:3.24

RUN addgroup -g 1001 easyrsa && \
    adduser --disabled-password \
    --gecos "" \
    --uid 1001 \
    --ingroup easyrsa \
    --home /app \
    --shell /sbin/nologin \
    easyrsa

RUN mkdir -p /app/data/pki /app/config && \
    chmod 700 /app/data/pki && \
    chmod 755 /app/config

RUN chown -R easyrsa:easyrsa /app
WORKDIR /app

RUN apk add --no-cache \
    ca-certificates \
    openssl \
    tini \
    bash && \
    rm -rf /var/cache/apk/*

COPY --from=build --chown=root:easyrsa /tmp/easyrsa/easyrsa /usr/local/bin/easyrsa
COPY --from=build --chown=easyrsa:easyrsa /tmp/easyrsa/x509-types /usr/local/bin/x509-types

RUN chmod -R 0550 /usr/local/bin/easyrsa
RUN chmod -R 0750 /usr/local/bin/x509-types

COPY --chown=easyrsa:easyrsa entrypoint.sh entrypoint.sh
RUN chmod 0550 entrypoint.sh

USER easyrsa:easyrsa
EXPOSE 0
HEALTHCHECK \
    --interval=60s \
    --timeout=5s \
    --start-period=10s \
    --retries=2 \
    CMD test -f /app/pki/.initialized || exit 1

ENTRYPOINT ["/sbin/tini", "--", "/app/entrypoint.sh"]