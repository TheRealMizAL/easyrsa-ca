#!/bin/bash
set -euo pipefail

export EASYRSA_BATCH="${EASYRSA_BATCH:-1}"

readonly EASYRSA_BIN="/usr/local/bin/easyrsa"
readonly PKI_LOCK_FILE="/app/data/pki/lock.file"

readonly ROOT_CA_CERT="${EXTERNAL_PKI}/root-ca.pem"
readonly INTERMEDIATE_KEY="${EXTERNAL_PKI}/intermediate-ca.key"
readonly INTERMEDIATE_CERT="${EXTERNAL_PKI}/intermediate-ca.crt"
readonly INTERMEDIATE_CHAIN="${EASYRSA_PKI}/chain.pem"

log()  { printf '[%s] [INFO]  %s\n' "$(date -u +%FT%TZ)" "$*"; }
warn() { printf '[%s] [WARN]  %s\n' "$(date -u +%FT%TZ)" "$*"; }
err()  { printf '[%s] [ERROR] %s\n' "$(date -u +%FT%TZ)" "$*"; }
die()  { err "$*"; exit 1; }
sep()  { log "================================================================"; }


check_prerequisites() {
    log "Checking prerequisites..."
    [ -f "${EASYRSA_BIN}" ]  || die "EasyRSA binary not found: ${EASYRSA_BIN}"
    [ -f "${EASYRSA_VARS_FILE}" ]    || die "vars file not found: ${EASYRSA_VARS_FILE}"
    command -v openssl >/dev/null 2>&1 || die "openssl binary not found"
    log "Prerequisites OK"
}


init_pki() {
    log "Initializing PKI directory structure..."
    "${EASYRSA_BIN}" init-pki

    touch "${EASYRSA_PKI}/serial"
    mkdir -p "${EASYRSA_PKI}/certs_by_serial"
    touch "${EASYRSA_PKI}/index.txt"
    echo "unique_subject = no" > "${EASYRSA_PKI}/index.txt.attr"

    log "PKI initialized"
}


verify_certs() {
    log "Verifying certificate chain..."

    [ -f "${ROOT_CA_CERT}" ]      || die "Root CA certificate not found: ${ROOT_CA_CERT}"
    [ -f "${INTERMEDIATE_CERT}" ] || die "Intermediate CA certificate not found: ${INTERMEDIATE_CERT}"
    [ -f "${INTERMEDIATE_KEY}" ]  || die "Intermediate CA private key not found: ${INTERMEDIATE_KEY}"

    local cert_pub key_pub
    cert_pub=$(openssl x509 -pubkey -noout -in "${INTERMEDIATE_CERT}" 2>/dev/null)
    key_pub=$(openssl pkey  -pubout -in "${INTERMEDIATE_KEY}"  2>/dev/null)
    [ "${cert_pub}" = "${key_pub}" ] \
        || die "Private key does not match the certificate"

    openssl verify -CAfile "${ROOT_CA_CERT}" "${INTERMEDIATE_CERT}" \
        || die "Certificate does not verify against Root CA"

    openssl x509 -checkend 0 -noout -in "${INTERMEDIATE_CERT}" \
        || die "Intermediate CA certificate has expired"

    if ! openssl x509 -checkend 2592000 -noout -in "${INTERMEDIATE_CERT}"; then
        warn "Intermediate CA certificate expires in less than 30 days"
    fi

    local is_ca
    is_ca=$(openssl x509 -noout -text -in "${INTERMEDIATE_CERT}" 2>/dev/null \
        | grep -c "CA:TRUE" || true)
    [ "${is_ca}" -ge 1 ] \
        || die "Certificate is not a CA certificate (CA:TRUE constraint missing)"

    log "Certificate verification OK"
}


build_chain() {
    log "Assembling certificate chain..."

    cat "${INTERMEDIATE_CERT}" "${ROOT_CA_CERT}" > "${INTERMEDIATE_CHAIN}"
    chmod 0644 "${INTERMEDIATE_CHAIN}"

    if [ ! -f "${EASYRSA_PKI}/ca.crt" ]; then
        cp "${INTERMEDIATE_CERT}" "${EASYRSA_PKI}/ca.crt"
        chmod 0644 "${EASYRSA_PKI}/ca.crt"
        log "Intermediate CA imported into PKI trust store"
    fi

    if [ ! -f "${EASYRSA_PKI}/private/ca.key" ]; then
        cp "${INTERMEDIATE_KEY}" "${EASYRSA_PKI}/private/ca.key"
        chmod 0644 "${EASYRSA_PKI}/private/ca.key"
        log "Intermediate key imported into PKI trust store"
    fi

    log "Chain assembled: ${INTERMEDIATE_CHAIN}"
}


fix_permissions() {
    chmod 700 "${EASYRSA_PKI}" "${EASYRSA_PKI}/private" 2>/dev/null || true
    find "${EASYRSA_PKI}/private" -type f -exec chmod 0600 {} \; 2>/dev/null || true
    find "${EASYRSA_PKI}/issued"  -type f -exec chmod 0644 {} \; 2>/dev/null || true
    find "${EASYRSA_PKI}/reqs"    -type f -exec chmod 0644 {} \; 2>/dev/null || true
}


stay_alive() {
    sep
    log "Intermediate CA is ready"
    sep
    log ""
    log "Available operations:"
    log ""
    log "  Generate certificate request:"
    log "    docker exec easyrsa-ca easyrsa gen-req <name> nopass"
    log ""
    log "  Sign server certificate:"
    log "    docker exec easyrsa-ca easyrsa sign-req server <name>"
    log ""
    log "  Sign client certificate:"
    log "    docker exec easyrsa-ca easyrsa sign-req client <name>"
    log ""
    log "  Revoke certificate:"
    log "    docker exec easyrsa-ca easyrsa revoke <name>"
    log ""
    log "  Update CRL:"
    log "    docker exec easyrsa-ca easyrsa gen-crl"
    log ""
    log "  Copy issued certificate to host:"
    log "    docker cp easyrsa-ca:${EASYRSA_PKI}/issued/<name>.crt ./"
    log "    docker cp easyrsa-ca:${EASYRSA_PKI}/private/<name>.key ./"
    sep

    exec tail -f /dev/null
}


main() {
    log "EasyRSA Intermediate CA starting..."

    check_prerequisites

    if [ ! -f "${PKI_LOCK_FILE}" ]; then
        warn "PKI not initialized. Running first-time setup..."
        init_pki
    else 
        warn "PKI already exists. Skip..."
    fi

    local notified_root=0
    local notified_intermediate=0

    while true; do
        if [ ! -f "${ROOT_CA_CERT}" ]; then
            if [ "${notified_root}" -eq 0 ]; then
                warn "Awaiting root CA certificate at: ${ROOT_CA_CERT}"
                notified_root=1
            fi
            sleep 10
            continue
        fi

        if [ ! -f "${INTERMEDIATE_CERT}" ]; then
            if [ "${notified_intermediate}" -eq 0 ]; then
                warn "Awaiting signed certificate at: ${INTERMEDIATE_CERT}"
                notified_intermediate=1
            fi
            sleep 10
            continue
        fi

        break
    done

    verify_certs
    build_chain
    fix_permissions
    stay_alive
}

main "$@"