# AutoMQ Admin / Operational Commands

## Cluster

```bash
kind get clusters
kubectl config current-context
kubectl get nodes -o wide
```

## AutoMQ

```bash
kubectl get all -n automq -o wide
kubectl get svc -n automq -o wide
kubectl get endpoints -n automq
```

## Conduktor

```bash
kubectl get all -n conduktor -o wide
kubectl get svc -n conduktor -o wide
kubectl get pvc -n conduktor
```

## Logs

```bash
kubectl logs -n automq deployment/automq-controller --tail=100
kubectl logs -n automq automq-broker-0 --tail=100
```

Follow:

```bash
kubectl logs -n automq automq-broker-0 -f
```

## Restart

```bash
kubectl rollout restart deployment/automq-controller -n automq
kubectl rollout restart statefulset/automq-broker -n automq
```

## Rollout

```bash
kubectl rollout status deployment/automq-controller -n automq
kubectl rollout status statefulset/automq-broker -n automq
```

## Listener config

```bash
kubectl exec -n automq automq-broker-0 --   sh -c 'grep -Ei "^(listeners|advertised.listeners|listener.security.protocol.map)" /opt/kafka/kafka/config/kraft/broker.properties'
```

## S3 config

```bash
kubectl exec -n automq automq-broker-0 --   sh -c 'grep -Ei "^(s3.data.buckets|s3.ops.buckets|s3.wal.path)" /opt/kafka/kafka/config/kraft/broker.properties'
```

## NodePorts

```bash
kubectl get svc automq-broker -n automq   -o jsonpath='{range .spec.ports[*]}{.name}{" port="}{.port}{" nodePort="}{.nodePort}{"\n"}{end}'
```

Expected:

```text
kafka port=9092 nodePort=32002
kafka-ext port=9094 nodePort=30094
```

Conduktor:

```bash
kubectl get svc conduktor-console -n conduktor   -o jsonpath='{range .spec.ports[*]}{.port}{" -> "}{.nodePort}{"\n"}{end}'
```

Expected:

```text
8080 -> 30080
```

## Exact image IDs

```bash
kubectl get pods -n automq   -o custom-columns='POD:.metadata.name,IMAGE:.spec.containers[*].image,IMAGE_ID:.status.containerStatuses[*].imageID'
```

## Ceph

```bash
source .env

AWS_ACCESS_KEY_ID="$CEPH_ACCESS_KEY" AWS_SECRET_ACCESS_KEY="$CEPH_SECRET_KEY" aws --endpoint-url "http://${CEPH_RGW_IP}:7480" --region us-east-1 s3 ls
```

## Events

```bash
kubectl get events -n automq --sort-by=.lastTimestamp
kubectl get events -n conduktor --sort-by=.lastTimestamp
```

## Describe

```bash
kubectl describe pod automq-broker-0 -n automq
kubectl describe deployment automq-controller -n automq
kubectl describe statefulset automq-broker -n automq
```

## Broker shell

```bash
kubectl exec -it -n automq automq-broker-0 -- /bin/sh
```

## KIND containers

```bash
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
```

## Backup live YAML

```bash
mkdir -p ~/automq-backup

kubectl get deployment automq-controller -n automq -o yaml > ~/automq-backup/controller.yaml
kubectl get statefulset automq-broker -n automq -o yaml > ~/automq-backup/broker.yaml
kubectl get svc -n automq -o yaml > ~/automq-backup/automq-services.yaml
kubectl get all -n conduktor -o yaml > ~/automq-backup/conduktor-all.yaml
kubectl get svc -n conduktor -o yaml > ~/automq-backup/conduktor-services.yaml
```

## Troubleshooting sequence

```bash
kubectl get nodes
kubectl get pods -n automq -o wide
kubectl get svc -n automq
kubectl get endpoints -n automq
kubectl get events -n automq --sort-by=.lastTimestamp
kubectl logs -n automq automq-broker-0 --tail=100
kubectl logs -n automq deployment/automq-controller --tail=100
```
