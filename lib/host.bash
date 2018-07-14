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

function create_security_group() {
  local vpcId="$1"
  local currentIp="$2"
  local instanceId=$(get_instance_id)
  local region=$(get_region)
  local groupId=$(aws ec2 create-security-group \
    --group-name "wdbp-${instanceId}" \
    --description 'Created by Win Docker Buildkite Plugin' \
    --vpc-id "${vpcId}" \
    --region "${region}" \
    --output text \
    --query 'GroupId')

  # allow docker 2375 on TCP
  aws ec2 authorize-security-group-ingress \
    --group-id "${groupId}" \
    --protocol tcp \
    --region "${region}" \
    --port 2375 \
    --cidr "$currentIp/32" > /dev/null

  echo "${groupId}"
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
  local newSecurityGroupId=$(create_security_group "${vpcId}" "${localIpv4}")
  local userData=$(get_windows_userdata)
  local instanceId=$(aws ec2 run-instances \
    --image-id "${AP_SOUTHEAST2_AMI}" \
    --count 1 \
    --instance-type "${instanceType}" \
    --security-group-ids "${newSecurityGroupId}" \
    --user-data "${userData}" \
    --region "${region}" \
    --instance-initiated-shutdown-behavior terminate \
    --subnet-id "${subnetId}" \
    --output text \
    --query 'Instances[0].InstanceId')
  echo "--- :ec2: Launching Windows EC2 Instance ${instanceId} for Windows Docker Container Support (${vpcId}, ${subnetId}, ${newSecurityGroupId})"
  aws ec2 wait instance-running \
    --instance-ids "${instanceId}" \
    --region "${region}"
  local instanceIp=$(get_instance_ip "${instanceId}")
  echo "--- :ec2: Windows EC2 Instance ${instanceId} running at ${instanceIp}"
}
