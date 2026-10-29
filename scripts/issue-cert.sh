#!/bin/bash
set -euo pipefail

FQDN=""
IP=""

usage() {
    echo "Usage: $0 <cert-type> --fqdn <fqdn> --ip <ip>"
    exit 2
}

if [[ $# -lt 1 || "$1" == -* ]]; then
    echo "Error:  <cert-type> не задан!" >&2
    usage
fi

CERT_TYPE="$1"
shift

while [[ $# -gt 0 ]]; do
    case "$1" in
        --fqdn)
            [[ $# -ge 2 ]] || { echo "Error: --fqdn требует значение!" >&2; usage; }
            FQDN="$2"
            shift 2
            ;;
        --ip)
            [[ $# -ge 2 ]] || { echo "Error: --ip требует значение!" >&2; usage; }
            IP="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Error: неизвестный параметр: $1" >&2
            usage
            ;;
    esac
done

[[ -n "$FQDN" ]] || { echo "Error: параметр --fqdn обязателен" >&2; usage; }
[[ -n "$IP"   ]] || { echo "Error: параметр --ip обязателен"   >&2; usage; }


[[ "$FQDN" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]] || { echo "Error: некорректный FQDN: $FQDN" >&2; exit 1; }
[[ "$IP" =~ ^((25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])$ ]] || { echo "Error: некорректный IP: $IP" >&2; exit 1; }


docker inspect -f '{{.State.Running}}' easyrsa-ca 2>/dev/null | grep -q true \
    || { echo "Error: контейнер easyrsa-ca не запущен" >&2; exit 1; }

docker exec easyrsa-ca easyrsa gen-req "${FQDN}" nopass
docker exec easyrsa-ca easyrsa --san="DNS:${FQDN},DNS:${FQDN%%.*},IP:${IP}" sign-req "${CERT_TYPE}" "${FQDN}"
docker cp "easyrsa-ca:/app/data/pki/issued/${FQDN}.crt" ./
docker cp "easyrsa-ca:/app/data/pki/private/${FQDN}.key" ./
