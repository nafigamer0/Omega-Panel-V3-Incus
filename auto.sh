#!/bin/bash

# Update package list (recommended)
apt update -y

# Install git
apt install git -y

# Clone the repository
git clone https://github.com/nafigamer0/Omega-Panel-V3-Incus.git

# Go into the directory
cd Omega-Panel-V3

# Give execute permission (just in case)
chmod +x setup.sh

# Run setup
sudo bash setup.sh