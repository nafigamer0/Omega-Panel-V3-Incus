#!/bin/bash
set -e

VPS_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$VPS_DIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

ok()  { echo -e "${GREEN}[OK]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; exit 1; }
step() { echo -e "\n${CYAN}==> $1${NC}"; }

if [ "$(id -u)" -ne 0 ]; then
    fail "Run as root: sudo bash setup_node.sh"
fi

step "1/6 — Install Incus"

INCUS_OK=false
if [ -S /var/lib/incus/unix.socket ]; then
    INCUS_OK=true
fi
if [ "$INCUS_OK" = false ] && command -v incus >/dev/null 2>&1; then
    INCUS_OK=true
fi

for pkg in lxd lxd-client lxc incus; do
    if command -v dpkg >/dev/null; then
        if timeout 5 dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
            echo "  Removing apt package: $pkg..."
            apt-get remove -y --purge "$pkg" || true
        fi
    fi
done
rm -f /usr/bin/lxc /usr/sbin/lxc /usr/bin/lxd /usr/sbin/lxd 2>/dev/null || true

if [ "$INCUS_OK" = true ]; then
    ok "Incus already installed"
else
    echo "  Installing Incus via Zabbly repository..."
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://pkgs.zabbly.com/key.asc -o /etc/apt/keyrings/zabbly.asc
    echo "deb [signed-by=/etc/apt/keyrings/zabbly.asc] https://pkgs.zabbly.com/incus/stable $(. /etc/os-release && echo $VERSION_CODENAME) main" | tee /etc/apt/sources.list.d/incus.list
    apt-get update
    apt-get install -y incus
    ok "Incus installed"
fi

step "2/6 — Initialize Incus"

echo "  Socket: /var/lib/incus/unix.socket"
for i in $(seq 1 30); do
    if [ -S /var/lib/incus/unix.socket ]; then
        break
    fi
    sleep 1
done
if [ ! -S /var/lib/incus/unix.socket ]; then
    fail "Incus socket not found"
fi
for i in $(seq 1 30); do
    if timeout 5 incus admin init --auto 2>/dev/null; then
        echo "  Incus daemon ready after ~${i}s"
        break
    fi
    sleep 2
done
ok "Incus running"

step "3/6 — Configure Incus"

apt-get install -y btrfs-progs 2>/dev/null || true

if timeout 10 incus storage show default >/dev/null 2>&1; then
    POOL_DRIVER=$(incus storage show default 2>/dev/null | grep "driver:" | awk "{print \$2}")
    ok "Storage pool 'default' already exists (driver: $POOL_DRIVER)"
else
    echo "  Creating storage pool 'default'..."
    if timeout 60 incus storage create default btrfs size=100GB 2>/dev/null; then
        ok "Storage pool 'default' created (btrfs)"
    else
        echo "  Falling back to dir pool..."
        timeout 60 incus storage create default dir 2>&1 || true
        if timeout 10 incus storage show default >/dev/null 2>&1; then
            ok "Storage pool 'default' created (dir)"
        else
            echo "  WARNING: Could not create storage pool"
        fi
    fi
fi

if ! timeout 10 incus network list 2>/dev/null | grep -q "incusbr0"; then
    echo "  Creating bridge network 'incusbr0'..."
    timeout 30 incus network create incusbr0 \
        --type=bridge \
        ipv4.address=10.132.115.1/24 \
        ipv4.nat=true \
        ipv6.address=none 2>&1 || true
    ok "Bridge network 'incusbr0' created"
else
    ok "Bridge network 'incusbr0' already exists"
fi

echo ""
echo "  Storage pools:"
timeout 10 incus storage list 2>/dev/null | sed 's/^/    /' || echo "  (unavailable)"
echo "  Networks:"
timeout 10 incus network list 2>/dev/null | sed 's/^/    /' || echo "  (unavailable)"

step "4/6 — Pre-download Ubuntu Incus images"
for ver in 22.04 24.04 26.04; do
    if timeout 10 incus image list 2>/dev/null | grep -q "$ver"; then
        ok "Ubuntu $ver already cached"
    else
        echo "  Downloading Ubuntu $ver..."
        timeout 300 incus image copy images:ubuntu/$ver local: --alias "$ver" --auto-update 2>&1 || \
        echo "  WARNING: Could not download Ubuntu $ver"
    fi
done
echo "  Cached images:"
timeout 15 incus image list 2>/dev/null | sed 's/^/    /' || echo "  (unavailable)"
ok "Incus images ready"

step "5/6 — Install Python 3.10 & packages"
if command -v python3.10 >/dev/null && python3.10 -m venv --help >/dev/null 2>&1; then
    ok "Python 3.10 already installed"
else
    echo "  Installing Python 3.10 from deadsnakes PPA..."
    apt-get update
    apt-get install -y software-properties-common
    add-apt-repository ppa:deadsnakes/ppa -y
    apt-get update
    apt-get install -y python3.10 python3.10-venv python3.10-distutils || {
        echo "  Falling back to default python3..."
        apt-get install -y python3 python3-venv python3-pip
    }
    ok "Python 3.10 installed"
fi
echo "  $(python3.10 --version 2>/dev/null || python3 --version 2>/dev/null)"

curl -sS https://bootstrap.pypa.io/get-pip.py | python3.10 2>/dev/null || python3 -m pip install --upgrade pip
python3.10 -m venv venv 2>/dev/null || python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install flask psutil gunicorn tzdata
ok "Python packages installed"

step "6/6 — Install system dependencies"
apt-get install -y socat
ok "socat installed"

echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}   Node Agent Setup Complete (Incus)${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
echo "  Start node agent:"
echo "    source venv/bin/activate"
echo "    python node.py"
echo ""
echo "  Cached Incus images:"
timeout 10 incus image list 2>/dev/null | sed 's/^/    /' || echo "    (none)"
echo ""