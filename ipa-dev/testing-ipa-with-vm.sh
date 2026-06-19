#!/usr/bin/env bash
# Launch a KVM-capable bare-metal EC2 host for the IPA VM sandbox.
# Handles accounts with NO default VPC (must specify VPC + subnet).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="$SCRIPT_DIR/sandbox-resources.env"   # sourceable record of what we created
AUDIT_LOG="$SCRIPT_DIR/sandbox-resources.log"    # cumulative launch history

# ── fill these in ────────────────────────────────────────────────
REGION="us-east-1"                                   # your AWS region
KEY_NAME="my-ec2-keypair"                    # existing EC2 key pair NAME
KEY_FILE="$HOME/.ssh/my-ec2-keypair.pem"     # matching private key file
MY_IP="$(curl -s https://checkip.amazonaws.com)"     # your IP for SSH allow (or hardcode)
INSTANCE_TYPE="c5.metal"                             # bare metal = required for KVM
NAME="ipa-sandbox"

# Optional: pin these if auto-discovery picks the wrong network.
VPC_ID=""        # e.g. vpc-0abc... (blank = first VPC in the region)
SUBNET_ID=""     # e.g. subnet-0abc... (blank = a public subnet in that VPC)
# ─────────────────────────────────────────────────────────────────

echo "Region=$REGION  MY_IP=$MY_IP"

# ── resolve VPC + subnet (this account has no default VPC) ────────
if [ -z "$VPC_ID" ]; then
  VPC_ID=$(aws ec2 describe-vpcs --region "$REGION" \
    --query 'Vpcs[0].VpcId' --output text)
fi
[ "$VPC_ID" = "None" ] && { echo "ERROR: no VPC in $REGION — set VPC_ID"; exit 1; }

if [ -z "$SUBNET_ID" ]; then
  # prefer a subnet that auto-assigns public IPs (so we can SSH in)
  SUBNET_ID=$(aws ec2 describe-subnets --region "$REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=map-public-ip-on-launch,Values=true" \
    --query 'Subnets[0].SubnetId' --output text)
  if [ "$SUBNET_ID" = "None" ]; then
    SUBNET_ID=$(aws ec2 describe-subnets --region "$REGION" \
      --filters "Name=vpc-id,Values=$VPC_ID" \
      --query 'Subnets[0].SubnetId' --output text)
    echo "WARN: no public subnet found; using $SUBNET_ID — may not get a public IP."
  fi
fi
[ "$SUBNET_ID" = "None" ] && { echo "ERROR: no subnet in $VPC_ID — set SUBNET_ID"; exit 1; }
echo "VPC=$VPC_ID  SUBNET=$SUBNET_ID"

# ── security group allowing SSH from your IP (in that VPC) ────────
SG_ID=$(aws ec2 create-security-group --region "$REGION" \
  --group-name "${NAME}-ssh-$$" --description "ipa sandbox ssh" \
  --vpc-id "$VPC_ID" \
  --query GroupId --output text)
aws ec2 authorize-security-group-ingress --region "$REGION" \
  --group-id "$SG_ID" --protocol tcp --port 22 --cidr "${MY_IP}/32"
echo "SG=$SG_ID"

# ── cloud-init: install KVM + libvirt + clone metal3-dev-env ──────
cat > /tmp/ipa-sandbox-userdata.sh <<'EOF'
#!/bin/bash
set -eux
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y git make qemu-kvm libvirt-daemon-system libvirt-clients \
  virtinst python3-venv jq curl
usermod -aG libvirt,kvm ubuntu
sudo -u ubuntu bash -lc 'cd ~ && git clone https://github.com/metal3-io/metal3-dev-env'
echo "ready: $(ls -l /dev/kvm)" > /home/ubuntu/SANDBOX_READY
chown ubuntu:ubuntu /home/ubuntu/SANDBOX_READY
EOF

# ── launch (add Spot via --instance-market-options if desired) ────
IID=$(aws ec2 run-instances --region "$REGION" \
  --image-id resolve:ssm:/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id \
  --instance-type "$INSTANCE_TYPE" \
  --key-name "$KEY_NAME" \
  --subnet-id "$SUBNET_ID" \
  --security-group-ids "$SG_ID" \
  --associate-public-ip-address \
  --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":100,"VolumeType":"gp3","DeleteOnTermination":true}}]' \
  --user-data file:///tmp/ipa-sandbox-userdata.sh \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${NAME}}]" \
  --query 'Instances[0].InstanceId' --output text)
echo "launched $IID — bare metal takes ~10-20 min to boot"

# ── wait for running, print the SSH command ──────────────────────
aws ec2 wait instance-running --region "$REGION" --instance-ids "$IID"
IP=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$IID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
# ── record what we created (so it's easy to clean up) ────────────
cat > "$STATE_FILE" <<EOF
# ipa-dev sandbox — AWS resources created by testing-ipa-with-vm.sh
# generated $(date -u +%Y-%m-%dT%H:%M:%SZ) — sourceable; used by cleanup-sandbox.sh
REGION=$REGION
INSTANCE_ID=$IID
SECURITY_GROUP_ID=$SG_ID
PUBLIC_IP=$IP
# pre-existing (do NOT delete) — recorded for reference only:
VPC_ID=$VPC_ID
SUBNET_ID=$SUBNET_ID
KEY_NAME=$KEY_NAME
KEY_FILE=$KEY_FILE
EOF
printf '%s  instance=%s sg=%s ip=%s region=%s\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$IID" "$SG_ID" "$IP" "$REGION" >> "$AUDIT_LOG"

echo
echo "INSTANCE: $IID    PUBLIC IP: $IP"
echo "recorded → $STATE_FILE"
echo "ssh -i $KEY_FILE ubuntu@$IP   # wait for ~/SANDBOX_READY, then: cd metal3-dev-env"
echo "clean up when done →  $SCRIPT_DIR/cleanup-sandbox.sh"
