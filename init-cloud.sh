#!/bin/bash

set +e  # Exit immediately if a command exits with a non-zero status

# Variables (replace with actual values or pass via cloud-init)
SSH_USER=$1
SSH_PASS=$2
SSH_HOST=$3
SSH_PORT=$4

echo "Setup Initiated" > /root/setup.log
# Install necessary packages
yum -y install epel-release
yum -y install htop wget vim telnet haproxy firewalld sshpass

echo "Installed requirements" >> /root/setup.log

# Configure firewall
firewall-offline-cmd --add-port $SSH_PORT/tcp
systemctl enable firewalld
systemctl start firewalld
firewall-cmd --add-port $SSH_PORT/tcp --permanent
firewall-cmd --add-port 80/tcp --permanent
firewall-cmd --add-port 80/udp --permanent
firewall-cmd --add-port 8080/tcp --permanent
firewall-cmd --add-port 8080/udp --permanent
firewall-cmd --add-port 443/tcp --permanent
firewall-cmd --add-port 443/udp --permanent
firewall-cmd --add-port 8443/tcp --permanent
firewall-cmd --add-port 8443/udp --permanent
firewall-cmd --add-port 2082/tcp --permanent
firewall-cmd --add-port 2082/udp --permanent
firewall-cmd --add-port 2083/tcp --permanent
firewall-cmd --add-port 2083/udp --permanent
firewall-cmd --reload

echo "Firewall configured" >> /root/setup.log
# Install Speedtest CLI
curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.rpm.sh | bash
yum -y install speedtest

echo "Installed speedtest" >> /root/setup.log
# Install Docker
yum install -y yum-utils
yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
yum install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
systemctl enable docker
systemctl start docker

# Verify Docker installation
docker ps
echo "Installed docker" >> /root/setup.log

# SSH Key Generation
#if [ ! -f ~/.ssh/id_rsa ]; then
#    ssh-keygen -t rsa -b 2048 -N "" -f ~/.ssh/id_rsa -q
#else
#    echo "SSH key already exists. Skipping key generation."
#fi
# sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -p $SSH_PORT $SSH_USER@$SSH_HOST "mkdir -p ~/.ssh && cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys"

# File transfers
sshpass -p "$SSH_PASS" scp -o StrictHostKeyChecking=no -r -P $SSH_PORT root@$SSH_HOST:/opt/wordpress/ /opt/
sshpass -p "$SSH_PASS" scp -o StrictHostKeyChecking=no -r -P $SSH_PORT root@$SSH_HOST:/opt/conf.d/ /opt/

# Start WordPress
cd /opt/wordpress/
docker compose up -d

echo "Installed wordpress" >> /root/setup.log
# Configure HAProxy
service haproxy start
sshpass -p "$SSH_PASS" scp -o StrictHostKeyChecking=no -P $SSH_PORT root@$SSH_HOST:/etc/haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg
service haproxy restart
docker ps

echo "Configured haproxy" >> /root/setup.log
# Configure SSH to use custom port
sed -i 's/#Port 22/Port '$SSH_PORT'/g' /etc/ssh/sshd_config
service sshd restart

echo "Changed ssh port" >> /root/setup.log
# Setup Outline VPN
sshpass -p "$SSH_PASS" scp -o StrictHostKeyChecking=no -r -P $SSH_PORT root@$SSH_HOST:/opt/outline/ /opt/
rm -rf /opt/outline/access.txt 
wget https://raw.githubusercontent.com/Jigsaw-Code/outline-server/master/src/server_manager/install_scripts/install_server.sh
chmod 755 install_server.sh
./install_server.sh --keys-port 443 --api-port 2083

echo "Installed outline-server" >> /root/setup.log
# Configure networking
sshpass -p "$SSH_PASS" scp -o StrictHostKeyChecking=no -r -P $SSH_PORT root@$SSH_HOST:/etc/sysconfig/network-scripts/ifcfg-eth0\:1 /etc/sysconfig/network-scripts/ifcfg-eth0\:1

# Extract IPADDR value
IPADDR=$(grep -oP 'IPADDR=\K[0-9.]*' /etc/sysconfig/network-scripts/ifcfg-eth0:1)

# Use the extracted IPADDR in the ip command
ip addr add $IPADDR dev eth0

echo "All done." >> /root/setup.log
