#!/bin/bash
set -euo pipefail


EASYRSA_PKI="${EASYRSA_PKI:-/app/pki}"
EASYRSA_EASYRSA_VARS_FILE="${EASYRSA_EASYRSA_VARS_FILE:-/app/config/vars}"
EASYRSA_BATCH="${EASYRSA_BATCH:-1}"

readonly LOG_FILE="/app/logs/easyrsa.log"
readonly EASYRSA_BIN="/usr/local/bin/easyrsa"
readonly INIT_MARKER="/app/.initialized"

readonly ROOT_CA_CERT="${EASYRSA_PKI}/root-ca.pem"
readonly INTERMEDIATE_CSR="${EASYRSA_PKI}/reqs/intermediate-ca.req"
readonly INTERMEDIATE_KEY="${EASYRSA_PKI}/private/intermediate-ca.key"
readonly INTERMEDIATE_CERT="${EASYRSA_PKI}/issued/intermediate-ca.crt"
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

    log "Generating intermediate CA private key and CSR..."
    "${EASYRSA_BIN}" gen-req intermediate-ca nopass

    chmod 0600 "${INTERMEDIATE_KEY}"
    chmod 0644 "${INTERMEDIATE_CSR}"

    touch "${INIT_MARKER}"

    sep
    log "PKI initialized. Manual steps required to complete setup:"
    sep
    log ""
    log "  Step 1. Copy the CSR from the container to the Linux host:"
    log "          docker cp easyrsa-ca:${INTERMEDIATE_CSR} ./intermediate-ca.req"
    log ""
    log "  Step 2. Transfer the CSR to the Windows host with CA access:"
    log "          scp ./intermediate-ca.req user@windows-host:C:\\Temp\\"
    log ""
    log "  Step 3. Submit the CSR to Windows CA (run on Windows host):"
    log "          certreq -submit -attrib \"CertificateTemplate:SubCA\" \\"
    log "                  C:\\Temp\\intermediate-ca.req C:\\Temp\\intermediate-ca.crt"
    log ""
    log "          Alternatively, via web enrollment UI:"
    log "          https://<ca-host>/certsrv -> Request a certificate ->"
    log "          Advanced certificate request -> paste .req file contents"
    log ""
    log "  Step 4. Transfer the signed certificate back to the Linux host:"
    log "          scp user@windows-host:C:\\Temp\\intermediate-ca.crt ./"
    log ""
    log "  Step 5. Transfer the Windows Root CA certificate to the Linux host:"
    log "          scp user@windows-host:C:\\Temp\\root-ca.pem ./"
    log ""
    log "  Step 6. Copy both files into the container:"
    log "          docker cp ./root-ca.pem      easyrsa-ca:${ROOT_CA_CERT}"
    log "          docker cp ./intermediate-ca.crt easyrsa-ca:${INTERMEDIATE_CERT}"
    log ""
    log "  Step 7. Restart the container:"
    log "          docker compose restart easyrsa"
    sep
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
        cp "${ROOT_CA_CERT}" "${EASYRSA_PKI}/ca.crt"
        chmod 0644 "${EASYRSA_PKI}/ca.crt"
        log "Root CA imported into PKI trust store"
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

    exec tail -f "${LOG_FILE}"
}


main() {
    log "EasyRSA Intermediate CA starting..."

    check_prerequisites

    if [ ! -f "${INIT_MARKER}" ]; then
        warn "PKI not initialized. Running first-time setup..."
        init_pki
    fi

    local notified_root=0
    local notified_intermediate=0

    while true; do
        if [ ! -f "${ROOT_CA_CERT}" ]; then
            if [ "${notified_root}" -eq 0 ]; then
                warn "Awaiting root CA certificate at: ${ROOT_CA_CERT}"
                warn "Refer to setup instructions in the log above"
                notified_root=1
            fi
            sleep 10
            continue
        fi

        if [ ! -f "${INTERMEDIATE_CERT}" ]; then
            if [ "${notified_intermediate}" -eq 0 ]; then
                warn "Awaiting signed certificate at: ${INTERMEDIATE_CERT}"
                warn "Refer to setup instructions in the log above"
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