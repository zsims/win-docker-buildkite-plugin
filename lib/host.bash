#!/bin/bash

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

function get_instance_ip() {
  local instanceId="$1"
  local region=$(get_region)
  aws ec2 describe-network-interfaces \
    --filter "Name=attachment.instance-id,Values=${instanceId}" \
    --region "${region}" \
    --output text \
    --query 'NetworkInterfaces[0].PrivateIpAddress'
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

# Ensures that the agent security group can get pings from
function ensure_agent_security_group_allows_ping() {
  local agentSecurityGroupId="$1"
  local windowsHostSecurityGroupId="$2"
  local region=$(get_region)

  # Ensure the agent can get ICMP pings from the windows host
  local existingSecurityIngress=$(aws ec2 describe-security-groups \
    --group-ids "${agentSecurityGroupId}" \
    --filters "Name=ip-permission.group-id,Values=${windowsHostSecurityGroupId}" \
      "Name=ip-permission.protocol,Values=icmp" \
    --region "${region}" \
    --output text \
    --query 'SecurityGroups[0].GroupId')

  # no ingress rule, create one
  if [[ "${existingSecurityIngress}" == 'None' ]]; then
    aws ec2 authorize-security-group-ingress \
      --group-id "${agentSecurityGroupId}" \
      --protocol icmp \
      --region "${region}" \
      --port '-1' \
      --source-group "${windowsHostSecurityGroupId}" > /dev/null
  fi
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

  # And shutdown if the agent instance no longer responds to pings
  local thisIpv4=$(get_local_ipv4)
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

# Script to Send 3 pings, with a 10s delay between each one -- if its down for 30s then shutdown
\$seppukuScript = @'
# Returns true if any of the pings are successful
if(!(Test-Connection -ComputerName '${thisIpv4}' -Count 3 -Delay 10 -Quiet)) {
  Stop-Computer -Force
}
'@
\$seppukuScript -Replace "\`n", "\`r\`n" | Out-File 'C:\seppuku.ps1' -Encoding ASCII

# Setup Scheduled task to shutdown when IP no longer responds to pings
\$action = New-ScheduledTaskAction -Execute 'Powershell.exe' -Argument '-NoProfile -WindowStyle Hidden -File "C:\seppuku.ps1"'
\$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 1)
Register-ScheduledTask -Action \$action -Trigger \$trigger -TaskName "Seppuku" -Description "Shutdown if ping lost"
</powershell>
EOF
}

function launch_ec2_host() {
  local instanceType="$1"
  local region=$(get_region)
  local vpcId=$(get_vpc_id)

  # Setup once off security groups
  local agentSecurityGroupId=$(ensure_agent_security_group "${vpcId}")
  local windowsHostSecurityGroupId=$(ensure_windows_host_security_group "${vpcId}" "${agentSecurityGroupId}")
  ensure_agent_security_group_allows_ping "${agentSecurityGroupId}" "${windowsHostSecurityGroupId}"

  local userData=$(get_windows_userdata)
  local subnetId=$(get_current_subnet_id)
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

  export WIN_DOCKER_HOST_INSTANCE_ID="${instanceId}"
  export WIN_DOCKER_HOST_IP="${instanceIp}"
}

# Returns 0 if the instance is usable (e.g. docker responding)
function is_instance_usable() {
  local instanceId="$1"
  local region=$(get_region)

  local instanceStatus=$(aws ec2 describe-instance-status \
    --instance-ids "${instanceId}" \
    --region "${region}" \
    --output text \
    --query 'InstanceStatuses[0].InstanceState.Name')

  # Instance does not exist
  if [[ "${instanceStatus}" == 'None' ]]; then
    echo "--- :ec2: Instance ${instanceId} does not exist"
    return 1
  fi

  if [[ "${instanceStatus}" == 'pending' ]]; then
    echo "--- :ec2: Instance pending, waiting for it to move into running state"
    aws ec2 wait instance-running --instance-ids "${instanceId}" --region "${region}"
  fi

  if [[ "${instanceStatus}" == 'running' ]]; then
    # TODO: check docker is responding
    echo "--- :ec2: Found running instance (${instanceId})"
    return 0
  fi

  return 2
}

function ensure_windows_ec2_host() {
  local instanceType="$1"
  local vpcId=$(get_vpc_id)
  local statusFile="$HOME/win-docker-instance"

  export WIN_DOCKER_HOST_PORT='2375'

  # check if there's already a running instance
  echo "--- :ec2: Checking for existing Windows EC2 Docker Host"
  if [[ -f "$statusFile" ]]; then
    local existingInstanceId=$(cat "${statusFile}")
    if is_instance_usable "${existingInstanceId}"; then
      # all good
      export WIN_DOCKER_HOST_IP=$(get_instance_ip "${existingInstanceId}")
      export WIN_DOCKER_HOST_INSTANCE_ID="${existingInstanceId}"
      return
    fi
  fi

  # no host healthy, launch it
  launch_ec2_host "${instanceType}"
  echo "${WIN_DOCKER_HOST_INSTANCE_ID}" > "${statusFile}"
}
