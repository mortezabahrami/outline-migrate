#!/bin/bash

set +e  # Don't exit on error

# Input vars
SSH_USER=$1
SSH_PASS=$2
SSH_HOST=$3
SSH_PORT=$4

echo "Setup Initiated" > /root/setup.log

# Test Gemini access
URL="https://gemini.google.com/"
response=$(curl -4 -s -w "%{http_code}" "$URL")
http_code="${response: -3}"
body="${response::-3}"
isBlocked=false

if [[ "$http_code" =~ ^4[0-9][0-9]$ ]] || [[ "$body" == *"Gemini isn’t currently supported in your country"* ]]; then
    isBlocked=true
fi

echo "isBlocked: $isBlocked"  >> /root/setup.log

# Install base packages
yum -y install epel-release
yum -y install htop wget vim telnet firewalld sshpass nginx

echo "Installed requirements including nginx" >> /root/setup.log

# Firewall setup
firewall-offline-cmd --add-port $SSH_PORT/tcp
systemctl enable firewalld
systemctl start firewalld
for port in $SSH_PORT 80 443 8080 8443 2082 2083; do
  for proto in tcp udp; do
    firewall-cmd --add-port=${port}/${proto} --permanent
  done
done
firewall-cmd --reload

echo "Firewall configured" >> /root/setup.log

# Install Speedtest
curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.rpm.sh | bash
yum -y install speedtest

echo "Installed speedtest" >> /root/setup.log

# Install Docker
yum install -y yum-utils
yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
yum install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
systemctl enable docker
systemctl start docker

docker ps || echo "Docker not running correctly"
echo "Installed docker" >> /root/setup.log

mkdir -p /var/log/sssd
echo "" > /var/log/sssd/sssd_kcm.log
# Remote data copy from old server
for item in conf.d outline myvpn; do
  sshpass -p "$SSH_PASS" scp -o StrictHostKeyChecking=no -r -P $SSH_PORT root@$SSH_HOST:/opt/$item/ /opt/
done

# nginx setup
systemctl enable nginx
systemctl start nginx
sshpass -p "$SSH_PASS" scp -o StrictHostKeyChecking=no -P $SSH_PORT root@$SSH_HOST:/etc/nginx/nginx.conf /etc/nginx/nginx.conf
systemctl restart nginx

echo "Configured nginx" >> /root/setup.log

# SSH custom port
sed -i 's/#Port 22/Port '$SSH_PORT'/g' /etc/ssh/sshd_config
systemctl restart sshd

echo "Changed ssh port" >> /root/setup.log

# Outline setup
rm -rf /opt/outline/access.txt
wget https://raw.githubusercontent.com/Jigsaw-Code/outline-server/master/src/server_manager/install_scripts/install_server.sh
chmod 755 install_server.sh
./install_server.sh --keys-port 443 --api-port 2083

echo "Installed outline-server" >> /root/setup.log

# Networking
sshpass -p "$SSH_PASS" scp -o StrictHostKeyChecking=no -r -P $SSH_PORT root@$SSH_HOST:/etc/sysconfig/network-scripts/ifcfg-eth0\:1 /etc/sysconfig/network-scripts/ifcfg-eth0\:1
IPADDR=$(grep -oP 'IPADDR=\K[0-9.]+' /etc/sysconfig/network-scripts/ifcfg-eth0:1)
ip addr add $IPADDR dev eth0

echo "All done." >> /root/setup.log
