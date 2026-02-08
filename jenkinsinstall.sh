#!/bin/bash
set -euo pipefail
echo "---------------------------------------------------------------------------"
echo " Jenkins Install script"
echo "---------------------------------------------------------------------------"
sleep 3
echo "System update"
sudo apt-get update
sudo apt-get install -y ca-certificates wget
echo "Install java"
sudo apt-get install -y fontconfig openjdk-21-jre
echo "Your java version : "
java -version
echo "Which Jenkins release do you want to install?"
echo "1) Long Term Support (LTS)"
echo "2) Weekly"
read -rp "Enter 1 or 2: " jenkins_choice
sudo install -m 0755 -d /etc/apt/keyrings
case "${jenkins_choice}" in
  1)
    echo "Selected: LTS (debian-stable)"
    sudo wget -O /etc/apt/keyrings/jenkins-keyring.asc \
      https://pkg.jenkins.io/debian-stable/jenkins.io-2026.key
    echo "deb [signed-by=/etc/apt/keyrings/jenkins-keyring.asc] https://pkg.jenkins.io/debian-stable binary/" | \
      sudo tee /etc/apt/sources.list.d/jenkins.list > /dev/null
    ;;
  2)
    echo "Selected: Weekly (debian)"
    sudo wget -O /etc/apt/keyrings/jenkins-keyring.asc \
      https://pkg.jenkins.io/debian/jenkins.io-2026.key
    echo "deb [signed-by=/etc/apt/keyrings/jenkins-keyring.asc] https://pkg.jenkins.io/debian binary/" | \
      sudo tee /etc/apt/sources.list.d/jenkins.list > /dev/null
    ;;
  *)
    echo "Invalid choice. Exiting."
    exit 1
    ;;
esac
sudo apt-get update
sudo apt-get install -y jenkins
sudo systemctl enable --now jenkins
sudo systemctl start jenkins
private_ip="$(hostname -I | awk '{print $1}')"
public_ip="$(wget -qO- https://api.ipify.org || true)"
initial_admin_password="$(sudo cat /var/lib/jenkins/secrets/initialAdminPassword || true)"
echo "Jenkins installed and started."
echo "Private IP: ${private_ip:-unknown}"
echo "Public IP: ${public_ip:-unknown}"
echo "Initial Admin Password: ${initial_admin_password:-unknown}"
sudo cat /var/lib/jenkins/secrets/initialAdminPassword  

