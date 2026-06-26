#!/bin/bash
growpart /dev/nvme0n1 4
lvextend -L +30G /dev/mapper/RootVG-varVol
xfs_growfs /var
dnf -y install dnf-plugins-core
dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo
dnf install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin -y
systemctl start docker
systemctl enable docker
usermod -aG docker ec2-user

curl -O https://s3.us-west-2.amazonaws.com/amazon-eks/1.34.2/2025-11-13/bin/linux/amd64/kubectl
chmod +x ./kubectl
mkdir -p $HOME/bin && cp ./kubectl  /usr/local/bin && export PATH=$HOME/bin:$PATH

ARCH=amd64
PLATFORM=$(uname -s)_$ARCH
curl -sLO "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_$PLATFORM.tar.gz"
tar -xzf eksctl_$PLATFORM.tar.gz -C /tmp && rm eksctl_$PLATFORM.tar.gz
sudo install -m 0755 /tmp/eksctl /usr/local/bin && rm /tmp/eksctl

mkdir -p /opt/eks

cat >/opt/eks/cluster.yaml <<'EOC'
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
    name: roboshop-dev
    region: us-east-1
managedNodeGroups:
  - name: roboshop-dev
    instanceTypes: ["m5.large", "c3.large","c4.large","c5.large"]
    desiredCapacity: 3 #  by default this value is 3
    spot: true
EOC

eksctl create cluster -f /opt/eks/cluster.yaml
