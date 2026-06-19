#!/usr/bin/env bash
# Tear down the ipa-dev sandbox AWS resources created by testing-ipa-with-vm.sh.
# Tag/name-based so it cleans up EVERY launch (even multiple), not just the last.
# Only deletes things this tooling created: instances tagged Name=ipa-sandbox,
# and security groups named ipa-sandbox-ssh-*. Never touches the VPC/subnet/key.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="$SCRIPT_DIR/sandbox-resources.env"

# Region: from state file if present, else default / env override
REGION="${REGION:-us-east-1}"
if [ -f "$STATE_FILE" ]; then
  REGION="$(grep -E '^REGION=' "$STATE_FILE" | tail -1 | cut -d= -f2)"
fi
echo "Region: $REGION"

# instances we created (any non-terminated state)
IIDS=$(aws ec2 describe-instances --region "$REGION" \
  --filters 'Name=tag:Name,Values=ipa-sandbox' \
            'Name=instance-state-name,Values=pending,running,stopping,stopped' \
  --query 'Reservations[].Instances[].InstanceId' --output text)

# security groups we created
SGIDS=$(aws ec2 describe-security-groups --region "$REGION" \
  --filters 'Name=group-name,Values=ipa-sandbox-ssh-*' \
  --query 'SecurityGroups[].GroupId' --output text)

echo "Instances to terminate:    ${IIDS:-<none>}"
echo "Security groups to delete: ${SGIDS:-<none>}"
if [ -z "$IIDS" ] && [ -z "$SGIDS" ]; then
  echo "Nothing to clean up."
  exit 0
fi

read -r -p "Proceed with deletion? [y/N] " ans
case "$ans" in y|Y) ;; *) echo "Aborted."; exit 1;; esac

# terminate instances first (SGs can't be deleted while in use)
if [ -n "$IIDS" ]; then
  # shellcheck disable=SC2086
  aws ec2 terminate-instances --region "$REGION" --instance-ids $IIDS >/dev/null
  echo "terminating: $IIDS"
  # shellcheck disable=SC2086
  aws ec2 wait instance-terminated --region "$REGION" --instance-ids $IIDS
  echo "instances terminated."
fi

# delete security groups (retry-friendly: ENIs take a moment to release)
for sg in $SGIDS; do
  if aws ec2 delete-security-group --region "$REGION" --group-id "$sg" 2>/dev/null; then
    echo "deleted SG $sg"
  else
    sleep 10
    aws ec2 delete-security-group --region "$REGION" --group-id "$sg" \
      && echo "deleted SG $sg (after retry)" \
      || echo "WARN: could not delete SG $sg — delete manually once detached"
  fi
done

# archive the state file so it's clear it's been cleaned
if [ -f "$STATE_FILE" ]; then
  mv "$STATE_FILE" "$STATE_FILE.cleaned-$(date -u +%Y%m%dT%H%M%SZ)"
  echo "archived state file."
fi

echo "Done."
