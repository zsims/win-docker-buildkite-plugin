#!/usr/bin/env bash

set -euo pipefail

# AMI for Windows Server 2016 Containers: https://aws.amazon.com/marketplace/pp/B06XX3NFQF
# TODO: Search for this automatically
AP_SOUTHEAST2_AMI='ami-a4f22dc6'

function get_local_ipv4() {
  curl -s 'http://169.254.169.254/latest/meta-data/local-ipv4'
}

function get_region() {
  curl -s 'http://169.254.169.254/latest/dynamic/instance-identity/document' | awk -F\" '/region/ {print $4}'
}

function get_mac_address() {
  curl -s 'http://169.254.169.254/latest/meta-data/mac'
}

function get_current_subnet_id() {
  local macAddress=$(get_mac_address)
  curl -s "http://169.254.169.254/latest/meta-data/network/interfaces/macs/${macAddress}/subnet-id"
}

function get_vpc_id() {
  local macAddress=$(get_mac_address)
  curl -s "http://169.254.169.254/latest/meta-data/network/interfaces/macs/${macAddress}/vpc-id"
}

function get_instance_id() {
  curl -s 'http://169.254.169.254/latest/meta-data/instance-id'
}

function ensure_security_group() {
  local vpcId="$1"
  local groupName="$2"
  local region=$(get_region)
  local existingSecurityGroupId=$(aws ec2 describe-security-groups \
    --group-names "${groupName}" \
    --filters "Name=vpc-id,Values=${vpcId}" \
    --region "${region}" \
    --output text \
    --query 'SecurityGroups[0].GroupId')

  # Have a security group already, return it
  if [[ "${existingSecurityGroupId}" != 'None' ]]; then
    echo "${existingSecurityGroupId}"
    return
  fi

  aws ec2 create-security-group \
    --group-name "${groupName}" \
    --description 'Created by Win Docker Buildkite Plugin' \
    --vpc-id "${vpcId}" \
    --region "${region}" \
    --output text \
    --query 'GroupId'
}

# Ensures the agent security group exists and returns its id
function ensure_agent_security_group() {
  local vpcId="$1"
  local groupName='win-docker-buildkite-plugin-agent'
  ensure_security_group "${vpcId}" "${groupName}"
}

# Ensures the windows host security group exists and returns its id
function ensure_windows_host_security_group() {
  local vpcId="$1"
  local agentSecurityGroupId="$2"
  local groupName='win-docker-buildkite-plugin-windows-host'
  local region=$(get_region)
  local groupId=$(ensure_security_group "${vpcId}" "${groupName}")

  # Check if there's an ingress rule from the agent sg to this one
  local existingSecurityIngress=$(aws ec2 describe-security-groups \
    --group-ids "${groupId}" \
    --filters "Name=ip-permission.group-id,Values=${agentSecurityGroupId}" \
    --region "${region}" \
    --output text \
    --query 'SecurityGroups[0].GroupId')

  # no ingress rule, create one -- all ports are allowed to permit interacting with launched containers
  if [[ "${existingSecurityIngress}" == 'None' ]]; then
    aws ec2 authorize-security-group-ingress \
      --group-id "${groupId}" \
      --protocol all \
      --region "${region}" \
      --port '0-65535' \
      --source-group "${agentSecurityGroupId}" > /dev/null
  fi

  echo "${groupId}"
}

# Ensures a security group is attached to an instance
function ensure_security_group_attached() {
  local instanceId="$1"
  local securityGroupId="$2"
  local region=$(get_region)

  local existingGroupIds=$(aws ec2 describe-instance-attribute \
    --instance-id "${instanceId}" \
    --region "${region}" \
    --attribute 'groupSet' \
    --output text \
    --query 'Groups[].GroupId' | tr '\n' ' ')

  # Ensure it's not already attached
  if echo "${existingGroupIds}" | grep -qi "${securityGroupId}"; then
    return
  fi

  # attach the new group, note that existing groups must be specified
  aws ec2 modify-instance-attribute \
    --instance-id "${instanceId}" \
    --region "${region}" \
    --groups ${existingGroupIds} ${securityGroupId}
}

function get_windows_userdata() {
  # Allow connection to the daemon per https://docs.microsoft.com/en-us/virtualization/windowscontainers/manage-docker/configure-docker-daemon
cat <<EOF
<powershell>
\$daemonConfig = @'
{
  "hosts": ["tcp://0.0.0.0:2375", "npipe://"]
}
'@
\$daemonConfig | Out-File 'C:\ProgramData\Docker\config\daemon.json' -Encoding ASCII
& netsh advfirewall firewall add rule name="Docker" dir=in action=allow protocol=TCP localport=2375
Restart-Service docker
</powershell>
EOF
}

function get_instance_ip() {
  local instanceId="$1"
  local region=$(get_region)
  aws ec2 describe-network-interfaces \
    --filter "Name=attachment.instance-id,Values=${instanceId}" \
    --region "${region}" \
    --output text \
    --query 'NetworkInterfaces[0].PrivateIpAddress'
}

function launch_ec2_host() {
  local instanceType="$1"
  local region=$(get_region)
  local subnetId=$(get_current_subnet_id)
  local vpcId=$(get_vpc_id)
  local localIpv4=$(get_local_ipv4)
  local agentSecurityGroupId=$(ensure_agent_security_group "${vpcId}")
  local windowsHostSecurityGroupId=$(ensure_windows_host_security_group "${vpcId}" "${agentSecurityGroupId}")
  local userData=$(get_windows_userdata)
  local instanceId=$(aws ec2 run-instances \
    --image-id "${AP_SOUTHEAST2_AMI}" \
    --count 1 \
    --instance-type "${instanceType}" \
    --security-group-ids "${windowsHostSecurityGroupId}" \
    --user-data "${userData}" \
    --region "${region}" \
    --instance-initiated-shutdown-behavior terminate \
    --subnet-id "${subnetId}" \
    --output text \
    --query 'Instances[0].InstanceId')
  echo "--- :ec2: Launching Windows EC2 Instance ${instanceId} for Windows Docker Container Support (${vpcId}, ${subnetId})"

  local thisInstanceId=$(get_instance_id)
  echo "--- :ec2: Ensuring agent instance (this machine, ${thisInstanceId}) has agent security group attached ${agentSecurityGroupId}"
  ensure_security_group_attached "${thisInstanceId}" "${agentSecurityGroupId}"

  aws ec2 wait instance-running \
    --instance-ids "${instanceId}" \
    --region "${region}"
  local instanceIp=$(get_instance_ip "${instanceId}")
  echo "--- :ec2: Windows EC2 Instance ${instanceId} running at ${instanceIp}"
}
