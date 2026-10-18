
#!/bin/bash
set -Eeuo pipefail

# Ubuntu 22.04 CI/CD tools installation
# Run as the ubuntu user with sudo privileges.

echo "===== Starting installation ====="

ARCH="$(dpkg --print-architecture)"
case "$ARCH" in
  amd64) DOWNLOAD_ARCH="amd64" ;;
  arm64) DOWNLOAD_ARCH="arm64" ;;
  *) echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac

# 1. Update system and install prerequisites
sudo apt-get update
sudo apt-get install -y \
  ca-certificates curl wget gnupg unzip lsb-release \
  apt-transport-https fontconfig

sudo install -d -m 0755 /etc/apt/keyrings

# 2. Install Java 21 (required by current Jenkins releases)
curl -fsSL https://packages.adoptium.net/artifactory/api/gpg/key/public \
  | sudo gpg --dearmor --yes -o /etc/apt/keyrings/adoptium.gpg

echo "deb [signed-by=/etc/apt/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb jammy main" \
  | sudo tee /etc/apt/sources.list.d/adoptium.list > /dev/null

sudo apt-get update
sudo apt-get install -y temurin-21-jdk
java -version

# 3. Install Jenkins LTS
sudo wget -q -O /etc/apt/keyrings/jenkins-keyring.asc \
  https://pkg.jenkins.io/debian-stable/jenkins.io-2026.key

echo "deb [signed-by=/etc/apt/keyrings/jenkins-keyring.asc] https://pkg.jenkins.io/debian-stable binary/" \
  | sudo tee /etc/apt/sources.list.d/jenkins.list > /dev/null

sudo apt-get update
sudo apt-get install -y jenkins
sudo systemctl enable --now jenkins

# 4. Install Docker
sudo apt-get install -y docker.io
sudo systemctl enable --now docker

# Allow Jenkins and ubuntu to use Docker.
# Docker group access is highly privileged; do not expose this host to untrusted users.
sudo usermod -aG docker jenkins
sudo usermod -aG docker ubuntu
sudo systemctl restart jenkins

# Do NOT use chmod 777 on /var/run/docker.sock.

# 5. Install AWS CLI v2
cd /tmp
curl -fsSL \
  "https://awscli.amazonaws.com/awscli-exe-linux-${DOWNLOAD_ARCH}.zip" \
  -o awscliv2.zip
unzip -oq awscliv2.zip -d /tmp
sudo /tmp/aws/install --update
aws --version
rm -rf /tmp/aws /tmp/awscliv2.zip

# 6. Install kubectl (match this to your EKS cluster version)
KUBECTL_VERSION="v1.33.0"

curl -fsSL -o /tmp/kubectl \
  "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${DOWNLOAD_ARCH}/kubectl"

sudo install -o root -g root -m 0755 /tmp/kubectl /usr/local/bin/kubectl
rm -f /tmp/kubectl
kubectl version --client

# 7. Install eksctl
PLATFORM="$(uname -s)_${DOWNLOAD_ARCH}"
curl -fsSL \
  "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_${PLATFORM}.tar.gz" \
  -o /tmp/eksctl.tar.gz

tar -xzf /tmp/eksctl.tar.gz -C /tmp
sudo install -m 0755 /tmp/eksctl /usr/local/bin/eksctl
rm -f /tmp/eksctl /tmp/eksctl.tar.gz
eksctl version

# 8. Install Terraform
curl -fsSL https://apt.releases.hashicorp.com/gpg \
  | sudo gpg --dearmor --yes -o /usr/share/keyrings/hashicorp-archive-keyring.gpg

echo "deb [arch=${ARCH} signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com jammy main" \
  | sudo tee /etc/apt/sources.list.d/hashicorp.list > /dev/null

sudo apt-get update
sudo apt-get install -y terraform
terraform -version

# 9. Install Trivy using its signed repository key
curl -fsSL https://aquasecurity.github.io/trivy-repo/deb/public.key \
  | sudo gpg --dearmor --yes -o /usr/share/keyrings/trivy.gpg

echo "deb [signed-by=/usr/share/keyrings/trivy.gpg] https://aquasecurity.github.io/trivy-repo/deb generic main" \
  | sudo tee /etc/apt/sources.list.d/trivy.list > /dev/null

sudo apt-get update
sudo apt-get install -y trivy
trivy --version

# 10. Install Helm 3
curl -fsSL -o /tmp/get_helm.sh \
  https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3

chmod 700 /tmp/get_helm.sh
sudo /tmp/get_helm.sh
rm -f /tmp/get_helm.sh
helm version

# 11. Start SonarQube in Docker
# Elasticsearch requires this kernel setting.
echo 'vm.max_map_count=262144' | sudo tee /etc/sysctl.d/99-sonarqube.conf > /dev/null
sudo sysctl --system

# Reuse an existing SonarQube container if present.
if sudo docker container inspect sonar >/dev/null 2>&1; then
  sudo docker start sonar
else
  sudo docker run -d \
    --name sonar \
    --restart unless-stopped \
    -p 9000:9000 \
    sonarqube:lts-community
fi

# 12. Verify key tools and services
echo "===== Installed tool versions ====="
java -version
sudo systemctl is-active jenkins
sudo systemctl is-active docker
docker --version
aws --version
kubectl version --client
eksctl version
terraform -version
trivy --version
helm version
sudo docker ps --filter name=sonar

echo "===== Installation script completed successfully ====="
