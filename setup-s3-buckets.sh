#!/usr/bin/env bash
# Creates the required S3 buckets in Ceph RGW for AutoMQ
# Usage: bash setup-s3-buckets.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$SCRIPT_DIR/.env" ]] || { echo "ERROR: .env file not found"; exit 1; }
set -a; source "$SCRIPT_DIR/.env"; set +a

: "${CEPH_RGW_IP:?ERROR: CEPH_RGW_IP not set in .env}"
ENDPOINT="http://${CEPH_RGW_IP}:7480"

aws --endpoint-url "$ENDPOINT" --region us-east-1 \
    s3 mb s3://automq-data 2>/dev/null || echo "automq-data already exists"

aws --endpoint-url "$ENDPOINT" --region us-east-1 \
    s3 mb s3://automq-wal 2>/dev/null || echo "automq-wal already exists"

echo "Buckets:"
aws --endpoint-url "$ENDPOINT" --region us-east-1 s3 ls