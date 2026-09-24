# Clean Installation / Uninstallation Guide

## 1. Copy configuration

```bash
cp .env.example .env
vi .env
chmod 600 .env
```

For direct LAN access:

```bash
KAFKA_EXTERNAL_HOST=192.168.10.70
KAFKA_EXTERNAL_PORT=30094
```

## 2. Validate host tools

```bash
docker --version
kind --version
kubectl version --client
aws --version
```

## 3. Precheck

```bash
chmod +x automq-install-uninstall.sh setup-s3-buckets.sh
./automq-install-uninstall.sh precheck
```

## 4. Verify Ceph

```bash
./automq-install-uninstall.sh ceph-check
```

## 5. Install

```bash
./automq-install-uninstall.sh install
```

The script:

1. validates tools and `.env`;
2. enables required kernel networking;
3. checks Ceph RGW;
4. creates KIND cluster `automq`;
5. creates `automq-data` and `automq-wal`;
6. creates namespace `automq`;
7. creates secret `automq-s3-credentials`;
8. renders AutoMQ manifests from `.env`;
9. deploys controller and broker;
10. deploys Conduktor/Postgres;
11. prints final status.

## 6. Expected KIND nodes

```text
automq-control-plane
automq-worker
automq-worker2
```

## 7. Expected AutoMQ services

```text
automq-broker            NodePort 9092:32002,9094:30094
automq-broker-headless   Headless 9092,9094
automq-controller        Headless 9093
```

## 8. Expected Conduktor service

```text
conduktor-console NodePort 8080:30080
```

## 9. Validate

```bash
./automq-install-uninstall.sh status
```

Then:

```bash
kubectl logs -n automq deployment/automq-controller --tail=100
kubectl logs -n automq automq-broker-0 --tail=100
```

Check listeners:

```bash
kubectl exec -n automq automq-broker-0 --   sh -c 'grep -Ei "^(listeners|advertised.listeners|listener.security.protocol.map)" /opt/kafka/kafka/config/kraft/broker.properties'
```

## 10. Safe uninstall

```bash
./automq-install-uninstall.sh uninstall
```

Removes only:

```text
namespace automq
namespace conduktor
```

Keeps:

```text
KIND cluster
Ceph buckets/data
local files
.env
```

## 11. Full KIND removal

```bash
./automq-install-uninstall.sh uninstall-all
```

This deletes KIND cluster `automq`.

It does not delete Ceph data.

## 12. Reinstall

```bash
./automq-install-uninstall.sh precheck
./automq-install-uninstall.sh ceph-check
./automq-install-uninstall.sh uninstall-all
./automq-install-uninstall.sh install
./automq-install-uninstall.sh status
```
