#!/usr/bin/env bash
# Launch a KVM-capable bare-metal EC2 host for the IPA VM sandbox.
# Handles accounts with NO default VPC (must specify VPC + subnet).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="$SCRIPT_DIR/sandbox-resources.env"   # sourceable record of what we created
AUDIT_LOG="$SCRIPT_DIR/sandbox-resources.log"    # cumulative launch history

# State file is written incrementally as resources are created, so it always
# reflects reality — even if we exit early (e.g. no capacity in any AZ).
# cleanup-sandbox.sh tears down whatever it lists, so a partial run is
# recoverable by just running cleanup. Resource vars are seeded empty and
# the state file is (re)written after each creation step via write_state().
SG_ID=""
IID=""
IP=""
write_state() {
  cat > "$STATE_FILE" <<EOF
# ipa-dev sandbox — AWS resources created by testing-ipa-with-vm.sh
# generated $(date -u +%Y-%m-%dT%H:%M:%SZ) — sourceable; used by cleanup-sandbox.sh
# written incrementally; blank IDs mean that resource was not created (yet).
REGION=$REGION
INSTANCE_ID=$IID
SECURITY_GROUP_ID=$SG_ID
PUBLIC_IP=$IP
# pre-existing (do NOT delete) — recorded for reference only:
VPC_ID=${VPC_ID:-}
SUBNET_ID=${SUBNET_ID:-}
KEY_NAME=$KEY_NAME
KEY_FILE=$KEY_FILE
EOF
}

# ── fill these in ────────────────────────────────────────────────
REGION="us-east-2"                                   # your AWS region
KEY_NAME="sys-eng-key-pair-abbas"                    # existing EC2 key pair NAME
KEY_FILE="~/.ssh/sys-eng-key-pair-abbas.pem"     # matching private key file
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

# Build a list of candidate subnets (one per AZ) so we can retry across AZs
# when an AZ has no c5.metal capacity (InsufficientInstanceCapacity).
if [ -n "$SUBNET_ID" ]; then
  SUBNET_CANDIDATES="$SUBNET_ID"
else
  # prefer subnets that auto-assign public IPs (so we can SSH in)
  SUBNET_CANDIDATES=$(aws ec2 describe-subnets --region "$REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=map-public-ip-on-launch,Values=true" \
    --query 'Subnets[].SubnetId' --output text)
  if [ -z "$SUBNET_CANDIDATES" ]; then
    SUBNET_CANDIDATES=$(aws ec2 describe-subnets --region "$REGION" \
      --filters "Name=vpc-id,Values=$VPC_ID" \
      --query 'Subnets[].SubnetId' --output text)
    echo "WARN: no public subnet found; candidates may not get a public IP."
  fi
fi
[ -z "$SUBNET_CANDIDATES" ] && { echo "ERROR: no subnet in $VPC_ID — set SUBNET_ID"; exit 1; }
echo "VPC=$VPC_ID  SUBNET_CANDIDATES=$SUBNET_CANDIDATES"

# ── security group allowing SSH from your IP (in that VPC) ────────
SG_ID=$(aws ec2 create-security-group --region "$REGION" \
  --group-name "${NAME}-ssh-$$" --description "ipa sandbox ssh" \
  --vpc-id "$VPC_ID" \
  --query GroupId --output text)
aws ec2 authorize-security-group-ingress --region "$REGION" \
  --group-id "$SG_ID" --protocol tcp --port 22 --cidr "${MY_IP}/32"
echo "SG=$SG_ID"
write_state   # record the SG now, so cleanup can find it even if launch fails

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

# ── launch, trying each AZ/subnet until one has capacity ──────────
# c5.metal capacity is per-AZ; an AZ can return InsufficientInstanceCapacity
# while another has stock, so we walk the candidate subnets in order.
SUBNET_ID=""
for SUBNET in $SUBNET_CANDIDATES; do
  echo "trying subnet $SUBNET ..."
  set +e
  RUN_OUT=$(aws ec2 run-instances --region "$REGION" \
    --image-id resolve:ssm:/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" \
    --subnet-id "$SUBNET" \
    --security-group-ids "$SG_ID" \
    --associate-public-ip-address \
    --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":100,"VolumeType":"gp3","DeleteOnTermination":true}}]' \
    --user-data file:///tmp/ipa-sandbox-userdata.sh \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${NAME}}]" \
    --query 'Instances[0].InstanceId' --output text 2>&1)
  RC=$?
  set -e
  if [ $RC -eq 0 ]; then
    IID="$RUN_OUT"
    SUBNET_ID="$SUBNET"
    echo "launched in $SUBNET"
    break
  fi
  if echo "$RUN_OUT" | grep -q "InsufficientInstanceCapacity"; then
    echo "  no $INSTANCE_TYPE capacity in this AZ — trying next subnet"
    continue
  fi
  # any other error is fatal
  echo "ERROR: run-instances failed:" >&2
  echo "$RUN_OUT" >&2
  exit 1
done

if [ -z "$IID" ]; then
  echo "ERROR: no $INSTANCE_TYPE capacity in any candidate AZ in $REGION." >&2
  echo "       Try another region, or wait and retry." >&2
  exit 1
fi
echo "launched $IID — bare metal takes ~10-20 min to boot"

# record the instance now (before the long wait) so cleanup can find it
write_state

# ── wait for running, print the SSH command ──────────────────────
aws ec2 wait instance-running --region "$REGION" --instance-ids "$IID"
IP=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$IID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
write_state   # now with the public IP filled in
printf '%s  instance=%s sg=%s ip=%s region=%s\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$IID" "$SG_ID" "$IP" "$REGION" >> "$AUDIT_LOG"

echo
echo "INSTANCE: $IID    PUBLIC IP: $IP"
echo "recorded → $STATE_FILE"
echo "ssh -i $KEY_FILE ubuntu@$IP   # wait for ~/SANDBOX_READY, then: cd metal3-dev-env"
echo "clean up when done →  $SCRIPT_DIR/cleanup-sandbox.sh"
