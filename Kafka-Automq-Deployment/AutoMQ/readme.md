The important fixes are now built into the manifests:

automq-broker is NodePort
9092 -> 32002
9094 -> 30094
automq-broker-headless exposes both 9092 and 9094
Conduktor console is NodePort
8080 -> 30080
KIND topology is fixed at 1 control-plane + 2 workers
AutoMQ is pinned to the exact image digest observed on the healthy VM
Ceph RGW remains configurable through .env
Kafka external advertised host/port are now configurable through .env, so you can use either direct LAN access or a future ngrok endpoint without editing YAML
Complete Git-ready package

Download AutoMQ Git-ready deployment package

It contains:

README.md
AUTOMQ_INSTALLATION_GUIDE.md
AUTOMQ_ADMIN_COMMANDS.md
automq-install-uninstall.sh
setup-s3-buckets.sh
kind-cluster.yaml
.env.example
.gitignore
automq-controller.yaml
automq-broker.yaml
conduktor.yaml

For your current LAN-based setup, your .env should look roughly like:

CEPH_RGW_IP=192.168.10.71
CEPH_ACCESS_KEY=<your-key>
CEPH_SECRET_KEY=<your-secret>

HOST_VM_IP=192.168.10.70

KAFKA_EXTERNAL_HOST=192.168.10.70
KAFKA_EXTERNAL_PORT=30094

Then installation is:

cp .env.example .env
vi .env
chmod 600 .env

chmod +x automq-install-uninstall.sh
chmod +x setup-s3-buckets.sh

./automq-install-uninstall.sh precheck
./automq-install-uninstall.sh ceph-check
./automq-install-uninstall.sh install

And validation:

./automq-install-uninstall.sh status
