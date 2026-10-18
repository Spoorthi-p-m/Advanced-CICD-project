#!/bin/bash
set -Eeuo pipefail

# ==========================================
# CI/CD Tools Installation - Ubuntu 22.04
# Jenkins + Docker + SonarQube + AWS EKS
# ==========================================

if [[ "$EUID" -eq 0 ]]; then
  echo "Run this script as the ubuntu user, not with sudo."
  exit 1
fi

if ! grep -q 'VERSION_ID="22.04"' /etc/os-release; then
  echo "Warning: This script was designed for Ubuntu 22.04."
fi

ARCH="$(dpkg --print-architecture)"
case "$ARCH" in
  amd64) BIN_ARCH="amd64" ;;
  arm64) BIN_ARCH="arm64" ;;
  *) echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac

echo "===== Installing prerequisites ====="
sudo apt-get update
sudo apt-get install -y \
  curl wget gnupg unzip ca-certificates \
  fontconfig apt-transport-https

sudo install -d -m 0755 /etc/apt/keyrings

# 1. Java 21
echo "===== Installing Java 21 ====="
curl -fsSL https://packages.adoptium.net/artifactory/api/gpg/key/public \
  | sudo gpg --dearmor --yes -o /etc/apt/keyrings/adoptium.gpg

echo "deb [signed-by=/etc/apt/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb jammy main" \
  | sudo tee /etc/apt/sources.list.d/adoptium.list >/dev/null

sudo apt-get update
sudo apt-get install -y temurin-21-jdk
java -version

# 2. Jenkins LTS
echo "===== Installing Jenkins ====="
sudo wget -q -O /etc/apt/keyrings/jenkins-keyring.asc \
  https://pkg.jenkins.io/debian-stable/jenkins.io-2026.key

echo "deb [signed-by=/etc/apt/keyrings/jenkins-keyring.asc] https://pkg.jenkins.io/debian-stable binary/" \
  | sudo tee /etc/apt/sources.list.d/jenkins.list >/dev/null

sudo apt-get update
sudo apt-get install -y jenkins
sudo systemctl enable --now jenkins

# 3. Docker
echo "===== Installing Docker ====="
sudo apt-get install -y docker.io
sudo systemctl enable --now docker

# Give Jenkins and ubuntu Docker access.
# Docker group membership grants powerful root-equivalent access.
sudo usermod -aG docker jenkins
sudo usermod -aG docker ubuntu

# 4. AWS CLI v2
echo "===== Installing AWS CLI ====="
cd /tmp
curl -fsSL \
  "https://awscli.amazonaws.com/awscli-exe-linux-${BIN_ARCH}.zip" \
  -o awscliv2.zip
unzip -oq awscliv2.zip -d /tmp
sudo /tmp/aws/install --update
rm -rf /tmp/aws /tmp/awscliv2.zip
aws --version

# 5. kubectl
echo "===== Installing kubectl ====="
# Match this to your EKS cluster's Kubernetes minor version.
KUBECTL_VERSION="v1.33.0"

curl -fsSL -o /tmp/kubectl \
  "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${BIN_ARCH}/kubectl"
sudo install -m 0755 /tmp/kubectl /usr/local/bin/kubectl
rm -f /tmp/kubectl
kubectl version --client

# 6. eksctl
echo "===== Installing eksctl ====="
PLATFORM="$(uname -s)_${BIN_ARCH}"

curl -fsSL \
  "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_${PLATFORM}.tar.gz" \
  -o /tmp/eksctl.tar.gz

tar -xzf /tmp/eksctl.tar.gz -C /tmp
sudo install -m 0755 /tmp/eksctl /usr/local/bin/eksctl
rm -f /tmp/eksctl /tmp/eksctl.tar.gz
eksctl version

# 7. Terraform
echo "===== Installing Terraform ====="
curl -fsSL https://apt.releases.hashicorp.com/gpg \
  | sudo gpg --dearmor --yes \
      -o /usr/share/keyrings/hashicorp-archive-keyring.gpg

echo "deb [arch=${ARCH} signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com jammy main" \
  | sudo tee /etc/apt/sources.list.d/hashicorp.list >/dev/null

sudo apt-get update
sudo apt-get install -y terraform
terraform -version

# 8. Trivy
echo "===== Installing Trivy ====="
curl -fsSL https://aquasecurity.github.io/trivy-repo/deb/public.key \
  | sudo gpg --dearmor --yes -o /usr/share/keyrings/trivy.gpg

echo "deb [signed-by=/usr/share/keyrings/trivy.gpg] https://aquasecurity.github.io/trivy-repo/deb generic main" \
  | sudo tee /etc/apt/sources.list.d/trivy.list >/dev/null

sudo apt-get update
sudo apt-get install -y trivy
trivy --version

# 9. Helm 3
echo "===== Installing Helm ====="
curl -fsSL -o /tmp/get_helm.sh \
  https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3

chmod 700 /tmp/get_helm.sh
sudo /tmp/get_helm.sh
rm -f /tmp/get_helm.sh
helm version

# 10. SonarQube prerequisites and container
echo "===== Configuring SonarQube ====="
echo 'vm.max_map_count=262144' \
  | sudo tee /etc/sysctl.d/99-sonarqube.conf >/dev/null
sudo sysctl --system

# Avoid creating a duplicate container on reruns.
if sudo docker container inspect sonar >/dev/null 2>&1; then
  sudo docker start sonar
else
  sudo docker run -d \
    --name sonar \
    --restart unless-stopped \
    -p 9000:9000 \
    sonarqube:lts-community
fi

# Restart Jenkins after Docker installation and group changes.
sudo systemctl restart jenkins

# 11. Verify everything
echo "===== Verification ====="
java -version
sudo systemctl is-active --quiet jenkins \
  && echo "Jenkins: running"
sudo systemctl is-active --quiet docker \
  && echo "Docker: running"
docker --version
aws --version
kubectl version --client
eksctl version
terraform -version
trivy --version
helm version
sudo docker ps --filter name=sonar

echo "===== Installation completed successfully ====="
echo "Jenkins: http://<EC2-PUBLIC-IP>:8080"
echo "SonarQube: http://<EC2-PUBLIC-IP>:9000"
echo "Restrict both ports to your IP in the EC2 security group."
