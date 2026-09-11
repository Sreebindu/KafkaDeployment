# KafkaDeployment
README.md


AutoMQ on KIND with Ceph RGW
This repository documents and automates the current working AutoMQ deployment.

Architecture
Ubuntu 26.04 LTS VM
└── Docker
    └── KIND cluster: automq
        ├── automq-control-plane
        ├── automq-worker
        ├── automq-worker2
        │
        ├── namespace: automq
        │   ├── automq-controller
        │   ├── automq-broker
        │   └── S3 credentials secret
        │
        └── namespace: conduktor
            ├── conduktor-console
            └── conduktor-postgres
Current known configuration
Host VM IP: 192.168.10.70

Ceph RGW: http://192.168.10.71:7480

KIND cluster: automq

Kubernetes: v1.36.1

KIND: 0.32.0

AutoMQ image: automqinc/automq:latest

Verified AutoMQ image digest:
sha256:68bf5df674ab9755da51f5200c152df391b0968aeeaf9ec4d12619517cd1234f

AutoMQ controller replicas: 1

AutoMQ broker replicas: 1

Kafka internal listener: 9092

Kafka external listener: 9094

Live broker NodePorts:

9092 -> 32002

9094 -> 30094

AutoMQ data bucket: automq-data

AutoMQ WAL bucket: automq-wal

AutoMQ cluster ID: rZdE0DjZSrqy96PXrMUZVw

Conduktor NodePort: 30080

Important source-of-truth note
The running Kubernetes objects were observed to differ from some local YAML files.

Examples:

Live automq-broker service is NodePort, while an older YAML copy showed ClusterIP.

Live Conduktor service is NodePort, while an older YAML copy showed ClusterIP.

Live Kafka advertised listener used 0.tcp.in.ngrok.io:13685, while an older YAML file advertised 192.168.10.70:9094.

For production-quality reinstallations, keep the Git manifests synchronized with the running configuration.

Required files
kind-cluster.yaml
.env
automq-controller.yaml
automq-broker.yaml
conduktor.yaml
setup-s3-buckets.sh
automq-install-uninstall.sh
Required .env
CEPH_RGW_IP=192.168.10.71
CEPH_ACCESS_KEY=<your-ceph-access-key>
CEPH_SECRET_KEY=<your-ceph-secret-key>
HOST_VM_IP=192.168.10.70
Protect it:

chmod 600 .env
Never commit real credentials to Git.

Quick start
chmod +x automq-install-uninstall.sh

./automq-install-uninstall.sh precheck
./automq-install-uninstall.sh install
./automq-install-uninstall.sh status
Uninstall options
Remove only AutoMQ and Conduktor workloads:

./automq-install-uninstall.sh uninstall
Delete the entire KIND cluster:

./automq-install-uninstall.sh uninstall-all
Validation
kubectl get nodes -o wide
kubectl get all -n automq -o wide
kubectl get all -n conduktor -o wide
kubectl get svc -n automq
kubectl get svc -n conduktor
Ceph validation
aws \
  --endpoint-url http://192.168.10.71:7480 \
  --region us-east-1 \
  s3 ls
Expected buckets:

automq-data
automq-wal
