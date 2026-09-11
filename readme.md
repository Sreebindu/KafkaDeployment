# AutoMQ — S3WAL on Ceph RGW

## Architecture
```
automq vcluster
  └── automq-controller (KRaft)
  └── automq-broker-0   (S3WAL → Ceph RGW)  ┐
  └── automq-broker-1   (S3WAL → Ceph RGW)  ├─ StatefulSet, node IDs from ordinal
  └── automq-broker-N   (S3WAL → Ceph RGW)  ┘
          │
          └──► Ceph RGW S3 endpoint (http://<CEPH_RGW_IP>:7480)
                    │
                    ├──► automq-data  (data bucket)
                    └──► automq-wal   (WAL bucket)
```

## Prerequisites
- Ceph RGW running and accessible on port `7480`
- Buckets created: `automq-data`, `automq-wal`
- Ceph RGW S3 user credentials (access key + secret key)

## ⚠️ Before deploying — fill in placeholders

Replace placeholders in the following files:

| File | Placeholder | Value |
|------|-------------|-------|
| `automq-broker.yaml` | `<CEPH_RGW_IP>` | IP of your Ceph RGW VM |
| `automq-controller.yaml` | `<CEPH_RGW_IP>` | IP of your Ceph RGW VM |
| `automq-secrets.yaml` | `<CEPH_ACCESS_KEY>` | Ceph RGW S3 access key |
| `automq-secrets.yaml` | `<CEPH_SECRET_KEY>` | Ceph RGW S3 secret key |

```bash
# Example — replace with your actual values
sed -i 's/<CEPH_RGW_IP>/192.168.1.100/g' automq-broker.yaml automq-controller.yaml
sed -i 's/<CEPH_ACCESS_KEY>/myaccesskey/g' automq-secrets.yaml
sed -i 's/<CEPH_SECRET_KEY>/mysecretkey/g' automq-secrets.yaml
```

## File reference

| File | Purpose |
|------|---------|
| `automq-secrets.yaml` | Ceph RGW S3 credentials secret |
| `automq-controller.yaml` | AutoMQ KRaft controller Deployment |
| `automq-broker.yaml` | AutoMQ broker StatefulSet + Services |
| `conduktor.yaml` | Conduktor UI + Postgres |

## Quick start

```bash
# Step 1 — Create S3 buckets in Ceph RGW
CEPH_RGW_IP=192.168.1.100 bash setup-s3-buckets.sh

# Step 2 — Deploy AutoMQ
CEPH_RGW_IP=192.168.1.100 bash deploy-automq.sh
```

## External access from other VMs

The broker exposes two listeners:
- `PLAINTEXT` on port `9092` — internal cluster use (Conduktor)
- `EXTERNAL` on port `9094` — external access from outside the cluster

The deploy script automatically starts a `socat` process that forwards `<HOST_VM_IP>:9094` → LoadBalancer IP → broker port `9094`.

To start it manually after a reboot:
```bash
EXTERNAL_IP=$(kubectl -n automq get svc automq-broker -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
nohup socat TCP-LISTEN:9094,fork,reuseaddr TCP:$EXTERNAL_IP:9094 > /tmp/socat-kafka-9094.log 2>&1 &
```

Connect from another VM:
```python
from confluent_kafka import Producer
p = Producer({'bootstrap.servers': '<HOST_VM_IP>:9094'})
p.produce('test-topic', b'hello')
p.flush()
```

> The advertised EXTERNAL listener is hardcoded to the host VM IP in `automq-broker.yaml`. If the host VM IP changes, update the `sed` line in the broker command and redeploy.


### Deploy
```bash
kubectl create namespace conduktor
kubectl apply -f conduktor.yaml
```

### Connect to AutoMQ cluster
1. Open Conduktor UI
2. Go to **Admin → Clusters → Add Cluster**
3. Fill in:

| Field | Value |
|-------|-------|
| Cluster name | `automq-cluster` |
| Technical ID | `automq-cluster` |
| Bootstrap servers | `automq-broker.automq.svc.cluster.local:9092` |
| Authentication | None |

4. Click **Test connection** then **Save**

### Access Conduktor UI from outside WSL
```bash
# Port-forward
kubectl -n conduktor port-forward svc/conduktor-console 8080:8080 --address 0.0.0.0 &

# Then open in browser
http://localhost:8080
```

## Scaling

### Scale brokers (instant — no rebalancing needed)
Brokers are a StatefulSet — each pod gets a unique node ID from its ordinal (broker-0=1, broker-1=2, etc). All state is in Ceph RGW, so scaling is instant:
```bash
# Scale up
kubectl -n automq scale statefulset/automq-broker --replicas=3

# Scale down
kubectl -n automq scale statefulset/automq-broker --replicas=1

# Check status
kubectl -n automq get statefulset automq-broker
```

### Scale controllers
Must be odd number for KRaft quorum (1, 3, 5):
```bash
# Scale up
kubectl -n automq scale deployment/automq-controller --replicas=3

# Scale down
kubectl -n automq scale deployment/automq-controller --replicas=1

# Check status
kubectl -n automq get deployment automq-controller
```
> When scaling controllers beyond 1, update `--controller.quorum.voters` in `automq-broker.yaml` and `automq-controller.yaml` to list all controller pod IPs.

### Recommended sizes

| Use case | Controllers | Brokers |
|----------|-------------|---------|
| Dev/test | 1 | 1 |
| HA prod | 3 | 2+ |
| High throughput | 3 | scale freely |

### Verify scaling

**Check pods are up:**
```bash
kubectl -n automq get pods -o wide
```

**Watch scale in real time:**
```bash
kubectl -n automq get pods -w
```

**Verify each broker has a unique node ID:**
```bash
for i in 0 1 2; do echo -n "broker-$i node.id: "; kubectl -n automq exec automq-broker-$i -- grep "^node.id" /opt/kafka/kafka/config/kraft/broker.properties; done
```

**Verify brokers registered with controller:**
```bash
for i in 0 1 2; do echo "=== broker-$i ==="; kubectl -n automq exec automq-broker-$i -- grep "Successfully registered" /opt/kafka/kafka/logs/server.log | tail -1; done
```

---

## TODOs
- [ ] Pin AutoMQ image to a specific version (replace `latest`)
- [ ] Tune controller/broker resource limits based on available RAM
- [ ] Add liveness/readiness probes once image entrypoint is confirmed
- [ ] Update `--controller.quorum.voters` when scaling controllers beyond 1