#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$SCRIPT_DIR/.env" ]] || { echo "ERROR: .env not found"; exit 1; }

set -a
source "$SCRIPT_DIR/.env"
set +a

: "${CEPH_RGW_IP:?CEPH_RGW_IP missing}"
: "${CEPH_ACCESS_KEY:?CEPH_ACCESS_KEY missing}"
: "${CEPH_SECRET_KEY:?CEPH_SECRET_KEY missing}"

ENDPOINT="http://${CEPH_RGW_IP}:7480"

export AWS_ACCESS_KEY_ID="$CEPH_ACCESS_KEY"
export AWS_SECRET_ACCESS_KEY="$CEPH_SECRET_KEY"

aws --endpoint-url "$ENDPOINT" --region us-east-1 \
  s3 mb s3://automq-data 2>/dev/null || echo "automq-data already exists"

aws --endpoint-url "$ENDPOINT" --region us-east-1 \
  s3 mb s3://automq-wal 2>/dev/null || echo "automq-wal already exists"

echo "Buckets:"
aws --endpoint-url "$ENDPOINT" --region us-east-1 s3 ls
