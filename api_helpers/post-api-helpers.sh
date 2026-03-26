#!/bin/bash
set -e

echo "Executing Post-API Helpers"

# =============================================================================
# Remove aws-controltower-VPC and all associated resources
# Deletion order: NAT GW → EIPs → IGW → Subnets → Route Tables → VPC
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
echo "Collecting NAT Gateway EIP allocations..."
EIP_ALLOC_IDS=$(aws ec2 describe-nat-gateways \
  --filter "Name=vpc-id,Values=$VPC_ID" "Name=state,Values=available,pending" \
  --query 'NatGateways[].NatGatewayAddresses[].AllocationId' \
  --output text)

# 2. Delete NAT Gateways
echo "Deleting NAT Gateways..."
NAT_IDS=$(aws ec2 describe-nat-gateways \
  --filter "Name=vpc-id,Values=$VPC_ID" "Name=state,Values=available,pending" \
  --query 'NatGateways[].NatGatewayId' \
  --output text)

for NAT_ID in $NAT_IDS; do
  echo "  Deleting NAT Gateway: $NAT_ID"
  aws ec2 delete-nat-gateway --nat-gateway-id "$NAT_ID"
done

# Wait for all NAT Gateways to finish deleting before releasing EIPs
if [ -n "$NAT_IDS" ]; then
  echo "  Waiting for NAT Gateways to be deleted (this may take a few minutes)..."
  for NAT_ID in $NAT_IDS; do
    aws ec2 wait nat-gateway-deleted --nat-gateway-ids "$NAT_ID"
    echo "  $NAT_ID deleted."
  done
fi

# 3. Release Elastic IPs
if [ -n "$EIP_ALLOC_IDS" ]; then
  echo "Releasing Elastic IPs..."
  for ALLOC_ID in $EIP_ALLOC_IDS; do
    echo "  Releasing EIP: $ALLOC_ID"
    aws ec2 release-address --allocation-id "$ALLOC_ID" || echo "  Could not release $ALLOC_ID — skipping."
  done
fi

# 4. Detach and delete Internet Gateways
echo "Deleting Internet Gateways..."
IGW_IDS=$(aws ec2 describe-internet-gateways \
  --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
  --query 'InternetGateways[].InternetGatewayId' \
  --output text)

for IGW_ID in $IGW_IDS; do
  echo "  Detaching IGW: $IGW_ID"
  aws ec2 detach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"
  echo "  Deleting IGW: $IGW_ID"
  aws ec2 delete-internet-gateway --internet-gateway-id "$IGW_ID"
done

# 5. Delete Subnets
echo "Deleting Subnets..."
SUBNET_IDS=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'Subnets[].SubnetId' \
  --output text)

for SUBNET_ID in $SUBNET_IDS; do
  echo "  Deleting Subnet: $SUBNET_ID"
  aws ec2 delete-subnet --subnet-id "$SUBNET_ID"
done

# 6. Delete non-main Route Tables (main RT is automatically deleted with the VPC)
echo "Deleting Route Tables..."
RT_IDS=$(aws ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'RouteTables[?!Associations[?Main==`true`]].RouteTableId' \
  --output text)

for RT_ID in $RT_IDS; do
  echo "  Deleting Route Table: $RT_ID"
  aws ec2 delete-route-table --route-table-id "$RT_ID" || echo "  Could not delete $RT_ID — skipping."
done

# 7. Delete the VPC
echo "Deleting VPC: $VPC_ID"
aws ec2 delete-vpc --vpc-id "$VPC_ID"

echo "aws-controltower-VPC and all associated resources successfully deleted."
