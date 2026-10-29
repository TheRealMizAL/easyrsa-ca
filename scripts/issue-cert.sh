#!/bin/bash
#
# Almost simple CA script for issuing client certificates
#
# Usage:
#   ./issue-cert.sh <cert-type> --fqdn <fqdn> --ip <ip> [--alg EC|RSA] [--keylen N] [--altcn NAME]

set -euo pipefail

usage() {
    echo "Usage: $0 <cert-type> --fqdn <fqdn> --ip <ip> [--alg EC|RSA] [--keylen N] [--altcn NAME]"
    exit 2
}

log()  { printf '[%s] [INFO]  %s\n' "$(date -u +%FT%TZ)" "$*"; }
warn() { printf '[%s] [WARN]  %s\n' "$(date -u +%FT%TZ)" "$*"; }
err()  { printf '[%s] [ERROR] %s\n' "$(date -u +%FT%TZ)" "$*"; }
die()  { err "$*"; exit 1; }
sep()  { log "================================================================"; }

FQDN=""
IP=""
ALG_TYPE="EC"
KEY_LEN="2048"
ALT_CN=""

[[ $# -ge 1 && "$1" != -* ]] || { echo "Error: cert-type is required" >&2; usage; }
CERT_TYPE="$1"
shift

while [[ $# -gt 0 ]]; do
    case "$1" in
        --fqdn)     [[ $# -ge 2 ]] || die "--fqdn requires a value";   FQDN="$2";     shift 2 ;;
        --ip)       [[ $# -ge 2 ]] || die "--ip requires a value";     IP="$2";       shift 2 ;;
        --alg)      [[ $# -ge 2 ]] || die "--alg requires a value";    ALG_TYPE="$2"; shift 2 ;;
        --keylen)   [[ $# -ge 2 ]] || die "--keylen requires a value"; KEY_LEN="$2";  shift 2 ;;
        --altcn)    [[ $# -ge 2 ]] || die "--altcn requires a value";  ALT_CN="$2";   shift 2 ;;
        -h|--help)  usage ;;
        -*)         die "unknown option: $1" ;;
        *)          die "unexpected positional argument: $1" ;;
    esac
done

[[ -n "$FQDN" ]] || die "--fqdn is required"
[[ -n "$IP"   ]] || die "--ip is required"
[[ "$ALG_TYPE" =~ ^(EC|RSA)$ ]] || die "invalid --alg: $ALG_TYPE (expected EC or RSA)"
[[ "$KEY_LEN" =~ ^[0-9]+$    ]] || die "invalid --keylen: $KEY_LEN (expected a positive integer)"


[[ "$FQDN" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]] || die "invalid FQDN: $FQDN"
log "FQDN is valid"
[[ "$IP" =~ ^((25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])$ ]] || die "invalid IP: $IP"
log "IP is valid"
warn "THIS SCRIPT DOESN'T CHECK THAT IP ACTUALLY CORRESPONDS WITH FQDN! BE CAREFUL!"


running="$(docker inspect -f '{{.State.Running}}' easyrsa-ca 2>/dev/null || true)"
[[ "$running" == "true" ]] || die "container easyrsa-ca is not active"
log "Docker container is active"

SAN="DNS:${FQDN},DNS:${FQDN%%.*},IP:${IP}"
SUBJECT_NAME="${ALT_CN:-$FQDN}"

ALGO_ARGS=()
if [[ "$ALG_TYPE" == "RSA" ]]; then
    ALGO_ARGS=("--use-algo=rsa" "--keysize=${KEY_LEN}")
    log "Using RSA with key size of ${KEY_LEN} bits"
else
    ALGO_ARGS=("--use-algo=ec")
    log "Using EC with secp256r1 curve"
fi

sep
log "Issuing certificate.."
docker exec easyrsa-ca easyrsa "${ALGO_ARGS[@]}" gen-req "$SUBJECT_NAME" nopass
docker exec easyrsa-ca easyrsa "--san=${SAN}" sign-req "$CERT_TYPE" "$SUBJECT_NAME"
log "Certificate issued"

docker cp "easyrsa-ca:/app/data/pki/issued/${SUBJECT_NAME}.crt" ./
docker cp "easyrsa-ca:/app/data/pki/private/${SUBJECT_NAME}.key" ./
log "Done!"
sep