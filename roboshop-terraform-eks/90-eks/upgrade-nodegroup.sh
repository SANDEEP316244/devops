#!/bin/bash

##### Colors ####
R="\e[31m"
G="\e[32m"
Y="\e[33m"
N="\e[0m"

CLUSTER_NAME="roboshop-dev"
AWS_REGION="us-east-1"

CURRENT_NG_VERSION="$1"  # blue|green
TARGET_NG_VERSION=""

LOGS_FOLDER="/home/ec2-user/eks-upgrade"
SCRIPT_NAME=$(echo "$0" | cut -d "." -f1)
LOG_FILE="$LOGS_FOLDER/$SCRIPT_NAME.log"

mkdir -p "$LOGS_FOLDER"
echo "Script started executed at: $(date)" | tee -a "$LOG_FILE"

VALIDATE(){
  if [ $1 -ne 0 ]; then
    echo -e "$2 ... $R FAILURE $N" | tee -a "$LOG_FILE"
    exit 1
  else
    echo -e "$2 ... $G SUCCESS $N" | tee -a "$LOG_FILE"
  fi
}

CONFIRM(){
  echo -e "${Y}$1${N}" | tee -a "$LOG_FILE"
  read -p "Type YES to continue: " ANS
  if [[ "$ANS" != "YES" ]]; then
    echo -e "${R}Aborted by user${N}" | tee -a "$LOG_FILE"
    exit 1
  fi
}

# ---- Args validation (keep only once)
if [[ $# -ne 1 ]]; then
  echo -e "${R}Usage:${N} $0 <CURRENT_NG_VERSION>" | tee -a "$LOG_FILE"
  echo -e "${R}Example:${N} $0 green" | tee -a "$LOG_FILE"
  exit 1
fi

if [[ "$CURRENT_NG_VERSION" != "blue" && "$CURRENT_NG_VERSION" != "green" ]]; then
  echo -e "${R}CURRENT_NG_VERSION must be either 'blue' or 'green'${N}" | tee -a "$LOG_FILE"
  exit 1
fi

if [[ "$CURRENT_NG_VERSION" == "blue" ]]; then
  TARGET_NG_VERSION="green"
else
  TARGET_NG_VERSION="blue"
fi

echo -e "${Y}Current nodegroup: $CURRENT_NG_VERSION${N}" | tee -a "$LOG_FILE"
echo -e "${Y}Target  nodegroup: $TARGET_NG_VERSION${N}" | tee -a "$LOG_FILE"

# --- Get current control plane version
CP_VERSION=$(aws eks describe-cluster \
  --name "$CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --query 'cluster.version' \
  --output text)
VALIDATE $? "Fetch current control plane version"
echo -e "${Y}Control plane version: $CP_VERSION${N}" | tee -a "$LOG_FILE"

# --- Detect current nodegroup kubelet minor version
KUBELET_VER=$(kubectl get nodes -l "nodegroup=${CURRENT_NG_VERSION}" \
  -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}' 2>/dev/null)

if [[ -z "$KUBELET_VER" ]]; then
  echo -e "${R}No nodes found with label nodegroup=${CURRENT_NG_VERSION}. Check node labels.${N}" | tee -a "$LOG_FILE"
  exit 1
fi

CURRENT_NG_K8S_VER=$(echo "$KUBELET_VER" | sed -E 's/^v([0-9]+\.[0-9]+).*/\1/')
if [[ -z "$CURRENT_NG_K8S_VER" ]]; then
  echo -e "${R}Failed to parse kubeletVersion: $KUBELET_VER${N}" | tee -a "$LOG_FILE"
  exit 1
fi

echo -e "${Y}${CURRENT_NG_VERSION} kubeletVersion: $KUBELET_VER -> detected $CURRENT_NG_K8S_VER${N}" | tee -a "$LOG_FILE"

# --- Terraform vars
ENABLE_BLUE=true
ENABLE_GREEN=true

if [[ "$CURRENT_NG_VERSION" == "green" ]]; then
  NG_GREEN_VERSION="$CURRENT_NG_K8S_VER"
  NG_BLUE_VERSION="$CP_VERSION"
else
  NG_BLUE_VERSION="$CURRENT_NG_K8S_VER"
  NG_GREEN_VERSION="$CP_VERSION"
fi

echo -e "${Y}Planned versions: blue=$NG_BLUE_VERSION green=$NG_GREEN_VERSION cp=$CP_VERSION${N}" | tee -a "$LOG_FILE"

# ---- STEP2-A: Create target nodegroup (enable both)


terraform plan \
  -var="eks_version=$CP_VERSION" \
  -var="enable_blue=$ENABLE_BLUE" \
  -var="enable_green=$ENABLE_GREEN" \
  -var="eks_nodegroup_blue_version=$NG_BLUE_VERSION" \
  -var="eks_nodegroup_green_version=$NG_GREEN_VERSION" | tee -a "$LOG_FILE"
VALIDATE ${PIPESTATUS[0]} "Terraform plan (create target)"
CONFIRM "STEP2-A: Create target nodegroup. Terraform PLAN now?"
terraform apply -auto-approve \
  -var="eks_version=$CP_VERSION" \
  -var="enable_blue=$ENABLE_BLUE" \
  -var="enable_green=$ENABLE_GREEN" \
  -var="eks_nodegroup_blue_version=$NG_BLUE_VERSION" \
  -var="eks_nodegroup_green_version=$NG_GREEN_VERSION" | tee -a "$LOG_FILE"
VALIDATE ${PIPESTATUS[0]} "Terraform apply (create target)"

# --- Wait for target nodes Ready
echo -e "${Y}Waiting for target nodes Ready: nodegroup=${TARGET_NG_VERSION}${N}" | tee -a "$LOG_FILE"
kubectl get nodes -l "nodegroup=${TARGET_NG_VERSION}" -o wide | tee -a "$LOG_FILE"

kubectl wait --for=condition=Ready node -l "nodegroup=${TARGET_NG_VERSION}" --timeout=30m 2>&1 | tee -a "$LOG_FILE"
VALIDATE ${PIPESTATUS[0]} "Wait for target nodes Ready"

# --- Remove upgrade taint from target nodes (if exists)
echo -e "${Y}Removing upgrade taint from target nodes (if exists): nodegroup=${TARGET_NG_VERSION}${N}" | tee -a "$LOG_FILE"
TARGET_NODES=$(kubectl get nodes -l "nodegroup=${TARGET_NG_VERSION}" -o name)
for n in $TARGET_NODES; do
  kubectl taint "$n" upgrade=true:NoSchedule- >/dev/null 2>&1
done
echo -e "${G}Taint removal attempted (safe if not present).${N}" | tee -a "$LOG_FILE"

# --- Cordon + Drain current nodes
CONFIRM "Proceed to cordon+drain CURRENT nodegroup=${CURRENT_NG_VERSION} ?"

echo -e "${Y}Cordoning current nodes: nodegroup=${CURRENT_NG_VERSION}${N}" | tee -a "$LOG_FILE"
kubectl cordon -l "nodegroup=${CURRENT_NG_VERSION}" 2>&1 | tee -a "$LOG_FILE"
VALIDATE ${PIPESTATUS[0]} "Cordon current nodegroup"

echo -e "${Y}Draining current nodes: nodegroup=${CURRENT_NG_VERSION}${N}" | tee -a "$LOG_FILE"
kubectl drain -l "nodegroup=${CURRENT_NG_VERSION}" \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --grace-period=60 \
  --timeout=30m 2>&1 | tee -a "$LOG_FILE"
VALIDATE ${PIPESTATUS[0]} "Drain current nodegroup"

echo -e "${Y}Quick check for unhealthy pods...${N}" | tee -a "$LOG_FILE"
kubectl get pods -A | egrep -i "Pending|CrashLoopBackOff|ImagePullBackOff" || true

# ---- STEP2-B: Delete current nodegroup
if [[ "$CURRENT_NG_VERSION" == "blue" ]]; then
  ENABLE_BLUE=false
  ENABLE_GREEN=true
else
  ENABLE_GREEN=false
  ENABLE_BLUE=true
fi
echo -e "${Y}Final vars: enable_blue=$ENABLE_BLUE enable_green=$ENABLE_GREEN${N}" | tee -a "$LOG_FILE"



terraform plan \
  -var="eks_version=$CP_VERSION" \
  -var="enable_blue=$ENABLE_BLUE" \
  -var="enable_green=$ENABLE_GREEN" \
  -var="eks_nodegroup_blue_version=$NG_BLUE_VERSION" \
  -var="eks_nodegroup_green_version=$NG_GREEN_VERSION" | tee -a "$LOG_FILE"
VALIDATE ${PIPESTATUS[0]} "Terraform plan (delete current)"
CONFIRM "STEP2-B: Delete current nodegroup ($CURRENT_NG_VERSION). Terraform PLAN now?"
terraform apply -auto-approve \
  -var="eks_version=$CP_VERSION" \
  -var="enable_blue=$ENABLE_BLUE" \
  -var="enable_green=$ENABLE_GREEN" \
  -var="eks_nodegroup_blue_version=$NG_BLUE_VERSION" \
  -var="eks_nodegroup_green_version=$NG_GREEN_VERSION" | tee -a "$LOG_FILE"
VALIDATE ${PIPESTATUS[0]} "Terraform apply (delete current)"

echo -e "${G}STEP 2 completed successfully. Target nodegroup=${TARGET_NG_VERSION} is now serving workloads.${N}" | tee -a "$LOG_FILE"
