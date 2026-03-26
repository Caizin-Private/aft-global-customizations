#!/bin/bash
set -e

echo "Executing Post-API Helpers"

# =============================================================================
# Remove aws-controltower-VPC and all associated resources
# NAT GW and EIPs are deleted manually (not in CF stack).
# Everything else (VPC, IGW, subnets, route tables) is deleted via the
# CloudFormation stack AWSControlTowerBP-VPC-ACCOUNT-FACTORY-V1.
# =============================================================================

echo "Checking for aws-controltower-VPC..."

VPC_ID=$(aws ec2 describe-vpcs \
  --filters "Name=tag:Name,Values=aws-controltower-VPC" \
  --query 'Vpcs[0].VpcId' \
  --output text)

if [ "$VPC_ID" == "None" ] || [ -z "$VPC_ID" ]; then
  echo "aws-controltower-VPC not found. Skipping."
  exit 0
fi

echo "Found VPC: $VPC_ID — proceeding with deletion."

# 1. Collect EIP allocation IDs from NAT Gateways before deleting them
EIP_ALLOC_IDS=$(aws ec2 describe-nat-gateways \
  --filter "Name=vpc-id,Values=$VPC_ID" "Name=state,Values=available,pending" \
  --query 'NatGateways[].NatGatewayAddresses[].AllocationId' \
  --output text)

# 2. Delete NAT Gateways and wait
NAT_IDS=$(aws ec2 describe-nat-gateways \
  --filter "Name=vpc-id,Values=$VPC_ID" "Name=state,Values=available,pending" \
  --query 'NatGateways[].NatGatewayId' \
  --output text)

if [ -n "$NAT_IDS" ]; then
  echo "Deleting NAT Gateways..."
  for NAT_ID in $NAT_IDS; do
    echo "  Deleting: $NAT_ID"
    aws ec2 delete-nat-gateway --nat-gateway-id "$NAT_ID"
  done
  echo "  Waiting for NAT Gateways to be deleted..."
  for NAT_ID in $NAT_IDS; do
    aws ec2 wait nat-gateway-deleted --nat-gateway-ids "$NAT_ID"
    echo "  $NAT_ID deleted."
  done
fi

# 3. Release Elastic IPs
if [ -n "$EIP_ALLOC_IDS" ]; then
  echo "Releasing Elastic IPs..."
  for ALLOC_ID in $EIP_ALLOC_IDS; do
    echo "  Releasing: $ALLOC_ID"
    aws ec2 release-address --allocation-id "$ALLOC_ID" || echo "  Could not release $ALLOC_ID — skipping."
  done
fi

# 4. Delete CloudFormation stack (cascades to VPC, IGW, subnets, route tables)
CF_STACK=$(aws cloudformation list-stacks \
  --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE \
  --query 'StackSummaries[?contains(StackName,`AWSControlTowerBP-VPC-ACCOUNT-FACTORY`)].StackName' \
  --output text)

if [ -n "$CF_STACK" ]; then
  echo "Deleting CloudFormation stack: $CF_STACK"
  aws cloudformation delete-stack --stack-name "$CF_STACK"
  aws cloudformation wait stack-delete-complete --stack-name "$CF_STACK"
  echo "Stack deleted — VPC and all resources removed."
else
  echo "No CF stack found — deleting VPC directly."
  aws ec2 delete-vpc --vpc-id "$VPC_ID"
fi

echo "aws-controltower-VPC and all associated resources successfully deleted."
