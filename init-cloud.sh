#!/bin/bash

set -e  # Exit immediately if a command exits with a non-zero status

# Variables (replace with actual values or pass via cloud-init)
SSH_USER=$1
SSH_PASS=$2
SSH_HOST=$3
SSH_PORT=$4

# Install necessary packages
yum -y install epel-release
yum -y install htop wget vim telnet haproxy firewalld

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

# Install Speedtest CLI
curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.rpm.sh | bash
yum -y install speedtest

# Install Docker
yum install -y yum-utils
yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
yum install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
systemctl enable docker
systemctl start docker

# Verify Docker installation
docker ps

# SSH Key Generation
ssh-keygen -t rsa -b 2048 -N "" -f ~/.ssh/id_rsa -q
sshpass -p "$SSH_PASS" ssh-copy-id -i ~/.ssh/id_rsa.pub -p $SSH_PORT $SSH_USER@$SSH_HOST

# File transfers
scp -r -P $SSH_PORT root@$SSH_HOST:/opt/wordpress/ /opt/
scp -r -P $SSH_PORT root@$SSH_HOST:/opt/conf.d/ /opt/

# Start WordPress
cd /opt/wordpress/
docker compose up -d

# Configure HAProxy
service haproxy start
scp -P $SSH_PORT root@$SSH_HOST:/etc/haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg
service haproxy restart
docker ps

# Configure SSH to use custom port
sed -i 's/#Port 22/Port '$SSH_PORT'/g' /etc/ssh/sshd_config
service sshd restart

# Setup Outline VPN
scp -r -P $SSH_PORT root@$SSH_HOST:/opt/outline/ /opt/
rm -rf /opt/outline/access.txt 
wget https://raw.githubusercontent.com/Jigsaw-Code/outline-server/master/src/server_manager/install_scripts/install_server.sh
chmod 755 install_server.sh
./install_server.sh --keys-port 443 --api-port 2083

# Configure networking
scp -r -P $SSH_PORT root@$SSH_HOST:/etc/sysconfig/network-scripts/ifcfg-eth0:1 /etc/sysconfig/network-scripts/ifcfg-eth0:1

# Finalize and reboot
reboot
