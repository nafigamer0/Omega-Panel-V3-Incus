# Omega Panel V3 Incus

A full-featured VPS management website built with Flask, Incus, and modern web technologies.

## Features
- User Authentication: Register and login system with secure password hashing
- Admin Panel: Create and manage VPS instances for users
- User Dashboard: View and manage your VPS instances
- Incus Integration: Automated VPS creation using Incus containers
- SSH Access: sshx-based SSH access to VPS instances
- Real-time Status: Auto-refreshing VPS status monitoring

## Default Credentials
- Admin Username: admin
- Admin Password: admin123

## Setup

### Prerequisites
- Python 3.10+
- Incus installed and initialized

## Installation

1. Clone the repository and run as root:
\`\`\`bash
sudo bash setup.sh
\`\`\`

Setup script performs:
- Installs system packages (curl, wget, jq, etc.)
- Installs Incus via Zabbly repository
- Removes conflicting apt packages
- Waits for Incus daemon readiness
- Creates default storage pool (dir)
- Creates incusbr0 bridge network
- Configures default profile (root disk + eth0)
- Pre-downloads Ubuntu images (22.04, 24.04, 26.04)
- Installs Python 3.10 if needed
- Installs pip
- Creates virtual environment (venv/)
- Installs requirements
- Initializes database

2. Start the panel:
\`\`\`bash
source venv/bin/activate
python app.py
\`\`\`

3. Open:
\`\`\`
http://localhost:5000
\`\`\`

4. Optional node:
\`\`\`bash
source venv/bin/activate
python node.py --port=5001 --name=node1
\`\`\`

## Manual Setup

### Install Incus:
\`\`\`bash
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.zabbly.com/key.asc | sudo tee /etc/apt/keyrings/zabbly.asc

echo "deb [signed-by=/etc/apt/keyrings/zabbly.asc] https://pkgs.zabbly.com/incus/stable $(. /etc/os-release && echo $VERSION_CODENAME) main" | sudo tee /etc/apt/sources.list.d/incus.list

sudo apt-get update
sudo apt-get install -y incus
sudo incus admin init --auto
\`\`\`

### Create venv:
\`\`\`bash
python3.10 -m venv venv
source venv/bin/activate
\`\`\`

### Install deps:
\`\`\`bash
pip install -r requirements.txt
\`\`\`

### Init DB:
\`\`\`bash
python -c "import app; app.init_db()"
\`\`\`

### Run:
\`\`\`bash
python app.py
\`\`\`

## Pre-pull Images
\`\`\`bash
incus image copy images:ubuntu/22.04 local: --alias 22.04 --auto-update
incus image copy images:ubuntu/24.04 local: --alias 24.04 --auto-update
incus image copy images:ubuntu/26.04 local: --alias 26.04 --auto-update
\`\`\`

## Usage

Admins:
- Login
- Open Admin Panel
- Create VPS
- Assign to user

Users:
- Register
- Login
- Manage VPS
- Use SSH terminal

## API
See Admin → API Docs