#!/usr/bin/env bash
# Tear down the ipa-dev sandbox AWS resources created by testing-ipa-with-vm.sh.
# Tag/name-based so it cleans up EVERY launch (even multiple), not just the last.
# Only deletes things this tooling created: instances tagged Name=ipa-sandbox,
# and security groups named ipa-sandbox-ssh-*. Never touches the VPC/subnet/key.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="$SCRIPT_DIR/sandbox-resources.env"

# Pull region + any recorded resource IDs from the state file. The create
# script writes it incrementally, so it lists whatever was created — even on a
# partial/failed launch. We delete the union of state-file IDs and tag/name
# discovery, so cleanup is idempotent and never leaks a partially-created run.
REGION="${REGION:-us-east-2}"
STATE_IID=""
STATE_SGID=""
if [ -f "$STATE_FILE" ]; then
  # shellcheck disable=SC1090
  . "$STATE_FILE"
  REGION="${REGION:-us-east-2}"
  STATE_IID="${INSTANCE_ID:-}"
  STATE_SGID="${SECURITY_GROUP_ID:-}"
fi
echo "Region: $REGION"

# de-dupe helper: collapse whitespace-separated tokens to a unique set
dedupe() { printf '%s\n' $* | awk 'NF && !seen[$0]++' | tr '\n' ' '; }

# instances we created (any non-terminated state) — tag discovery ∪ state file
IIDS=$(aws ec2 describe-instances --region "$REGION" \
  --filters 'Name=tag:Name,Values=ipa-sandbox' \
            'Name=instance-state-name,Values=pending,running,stopping,stopped' \
  --query 'Reservations[].Instances[].InstanceId' --output text)
# shellcheck disable=SC2086
IIDS=$(dedupe $IIDS $STATE_IID)

# security groups we created — tag discovery ∪ state file
SGIDS=$(aws ec2 describe-security-groups --region "$REGION" \
  --filters 'Name=group-name,Values=ipa-sandbox-ssh-*' \
  --query 'SecurityGroups[].GroupId' --output text)
# shellcheck disable=SC2086
SGIDS=$(dedupe $SGIDS $STATE_SGID)

echo "Instances to terminate:    ${IIDS:-<none>}"
echo "Security groups to delete: ${SGIDS:-<none>}"
if [ -z "$IIDS" ] && [ -z "$SGIDS" ]; then
  echo "Nothing to clean up."
  exit 0
fi

read -r -p "Proceed with deletion? [y/N] " ans
case "$ans" in y|Y) ;; *) echo "Aborted."; exit 1;; esac

# terminate instances first (SGs can't be deleted while in use).
# Tolerant of IDs that are already gone, so re-running cleanup is safe.
if [ -n "$IIDS" ]; then
  # shellcheck disable=SC2086
  aws ec2 terminate-instances --region "$REGION" --instance-ids $IIDS >/dev/null 2>&1 \
    || echo "WARN: some instances already gone — continuing"
  echo "terminating: $IIDS"
  # shellcheck disable=SC2086
  aws ec2 wait instance-terminated --region "$REGION" --instance-ids $IIDS 2>/dev/null || true
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
