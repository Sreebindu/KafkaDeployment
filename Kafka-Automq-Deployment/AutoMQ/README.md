# KafkaDeployment / AutoMQ

This folder is a Git-ready version of the AutoMQ deployment reconstructed from the healthy running VM.

## What was synchronized

The manifests now match the live service topology:

- AutoMQ broker service: `NodePort`
  - `9092 -> 32002`
  - `9094 -> 30094`
- AutoMQ broker headless service exposes both `9092` and `9094`.
- Conduktor console service: `NodePort`
  - `8080 -> 30080`
- KIND topology:
  - 1 control-plane
  - 2 workers
- Ceph RGW:
  - `192.168.10.71:7480`
- S3 buckets:
  - `automq-data`
  - `automq-wal`
- AutoMQ image is pinned to the digest observed on the healthy VM.

## External Kafka address

The live broker previously advertised an ngrok endpoint, but no ngrok process/service/container was found on this VM.

For that reason the Git version uses:

```bash
KAFKA_EXTERNAL_HOST=
KAFKA_EXTERNAL_PORT=
```

from `.env`.

For direct LAN/NodePort access, use:

```bash
KAFKA_EXTERNAL_HOST=192.168.10.70
KAFKA_EXTERNAL_PORT=30094
```

If you later use ngrok, put the current public TCP hostname/port in `.env` before deployment.

## Setup

```bash
cp .env.example .env
vi .env
chmod 600 .env

chmod +x automq-install-uninstall.sh
chmod +x setup-s3-buckets.sh

./automq-install-uninstall.sh precheck
./automq-install-uninstall.sh ceph-check
./automq-install-uninstall.sh install
```

## Status

```bash
./automq-install-uninstall.sh status
```

## Safe uninstall

```bash
./automq-install-uninstall.sh uninstall
```

Keeps KIND and Ceph data.

## Full cluster removal

```bash
./automq-install-uninstall.sh uninstall-all
```

Deletes KIND cluster only. Ceph data is retained.

## Important

Never commit `.env`.

Recommended `.gitignore`:

```text
.env
.rendered/
*.log
*.tar.gz
```
