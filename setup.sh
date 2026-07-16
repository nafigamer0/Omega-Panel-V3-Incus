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
    fail "Run as root: sudo bash setup.sh"
fi

step "1/11 — System packages"
echo "  Running: apt-get update..."
apt-get update
echo "  Running: apt-get install system packages..."
apt-get install -y curl wget gnupg2 ca-certificates lsb-release socat jq software-properties-common
ok "System packages installed"

step "2/11 — Install Incus"

INCUS_OK=false

# Quick check: is Incus socket already alive?
if [ -S /var/lib/incus/unix.socket ]; then
    INCUS_OK=true
fi

# Also check: does incus command already work?
if [ "$INCUS_OK" = false ] && command -v incus >/dev/null 2>&1; then
    INCUS_OK=true
fi

# Remove conflicting apt packages
for pkg in lxd lxd-client lxc incus; do
    if command -v dpkg >/dev/null; then
        if timeout 5 dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
            echo "  Removing apt package: $pkg..."
            apt-get remove -y --purge "$pkg" || true
        fi
    fi
done

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

# Ensure old custom hook script doesn't interfere
rm -f /opt/incus-lxcfs-mount.sh

step "3/11 — Initialize Incus"

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

echo "  Incus socket ready, waiting for daemon to accept requests..."
for i in $(seq 1 30); do
    if timeout 5 incus admin init --auto 2>/dev/null; then
        echo "  Incus daemon ready after ~${i}s"
        break
    fi
    if [ "$i" -eq 20 ]; then
        echo "  (still waiting... incus not responding yet)"
    fi
    sleep 2
done

step "4/11 — Setup LXCFS (correct container resource views)"
echo "  Installing lxcfs..."
apt-get install -y lxcfs
# Create systemd drop-in to bypass ConditionVirtualization=!container (we run inside Docker)
mkdir -p /etc/systemd/system/incus-lxcfs.service.d
cat > /etc/systemd/system/incus-lxcfs.service.d/override.conf << 'OVERRIDE'
[Unit]
ConditionVirtualization=
OVERRIDE
systemctl daemon-reload 2>/dev/null || true
# Kill any stale lxcfs and restart via systemd at /var/lib/incus-lxcfs (path Incus expects)
pkill -9 lxcfs 2>/dev/null || true
sleep 1
umount -l /var/lib/lxcfs 2>/dev/null || true
umount -l /var/lib/incus-lxcfs 2>/dev/null || true
rm -rf /var/lib/incus-lxcfs /var/lib/lxcfs 2>/dev/null || true
systemctl start incus-lxcfs.service 2>/dev/null || true
sleep 2
if mount | grep -q "lxcfs.*incus-lxcfs"; then
    ok "LXCFS running at /var/lib/incus-lxcfs"
    echo "  Memory from lxcfs: $(cat /var/lib/incus-lxcfs/proc/meminfo 2>/dev/null | head -1)"
else
    echo "  Trying fallback: starting lxcfs directly..."
    mkdir -p /var/lib/incus-lxcfs
    nohup lxcfs /var/lib/incus-lxcfs > /var/log/lxcfs.log 2>&1 &
    disown
    sleep 2
    if mount | grep -q "lxcfs.*incus-lxcfs"; then
        ok "LXCFS running at /var/lib/incus-lxcfs (fallback)"
        echo "  Memory from lxcfs: $(cat /var/lib/incus-lxcfs/proc/meminfo 2>/dev/null | head -1)"
    else
        echo "  WARNING: lxcfs not mounted; container free -h will show host totals"
    fi
fi

# Create the lxc.mount.hook wrapper that fixes empty cpuinfo from lxcfs
step "4b/11 — Install lxcfs mount wrapper for cpuinfo"
cat > /opt/incus-lxcfs-mount-wrapper.sh << 'WRAPPER'
#!/bin/sh
# Wrapper around Incus's built-in lxc.mount.hook
# Fixes /proc/cpuinfo and /sys/devices/system/cpu/ when lxcfs returns
# empty/host data (nested Docker environments)
/opt/incus/share/lxcfs/lxc.mount.hook "$@"
LXC_ROOTFS="${LXC_ROOTFS_MOUNT}"
NPROC=1
BACKUP_YAML="/var/lib/incus/containers/${LXC_NAME}/backup.yaml"
if [ -f "$BACKUP_YAML" ]; then
    CONFIG_NPROC=$(grep -A2 'limits.cpu' "$BACKUP_YAML" 2>/dev/null | head -1 | sed 's/.*: *"\(.*\)"/\1/' | sed 's/[^0-9]//g')
    [ -n "$CONFIG_NPROC" ] && [ "$CONFIG_NPROC" -gt 0 ] 2>/dev/null && NPROC=$CONFIG_NPROC
fi
TMP_DIR="${LXC_ROOTFS}/dev/.lxc-cpuinfo"
mkdir -p "$TMP_DIR" 2>/dev/null
mount -t tmpfs tmpfs "$TMP_DIR" 2>/dev/null || true
CPUINFO_EMPTY=false
if [ -f "${LXC_ROOTFS}/proc/cpuinfo" ]; then
    READ_BYTES=$(head -c 1 "${LXC_ROOTFS}/proc/cpuinfo" 2>/dev/null | wc -c)
    [ "$READ_BYTES" = "0" ] && CPUINFO_EMPTY=true
fi
if [ "$CPUINFO_EMPTY" = true ]; then
    umount -n "${LXC_ROOTFS}/proc/cpuinfo" 2>/dev/null || true
    MODEL="AMD EPYC Processor"
    VENDOR="AuthenticAMD"
    FLAGS="fpu vme de pse tsc msr pae mce cx8 apic sep mtrr pge mca cmov pat pse36 clflush mmx fxsr sse sse2 ss ht syscall nx pdpe1gb rdtscp lm constant_tsc rep_good nopl cpuid tsc_known_freq pni pclmulqdq ssse3 fma cx16 pcid sse4_1 sse4_2 x2apic movbe popcnt aes xsave avx f16c rdrand hypervisor lahf_lm abm 3dnowprefetch cpuid_fault invpcid_single pti ssbd ibrs ibpb stibp fsgsbase bmi1 hle avx2 smep bmi2 erms invpcid rtm avx512f avx512dq rdseed adx smap avx512ifma clflushopt clwb avx512cd sha_ni avx512bw avx512vl xsaveopt xsavec xgetbv1 xsaves arat avx512vbmi umip pku ospke avx512_vbmi2 gfni vaes vpclmulqdq avx512_vnni avx512_bitalg avx512_vpopcntdq rdpid"
    MHZ="3294.688"
    CACHE="16384 KB"
    CPUINFO_FILE="${TMP_DIR}/cpuinfo"
    > "$CPUINFO_FILE"
    i=0
    while [ "$i" -lt "$NPROC" ]; do
        cat << EOF >> "$CPUINFO_FILE"
processor	: $i
vendor_id	: $VENDOR
cpu family	: 25
model		: 17
model name	: $MODEL
stepping	: 4
cpu MHz		: $MHZ
cache size	: $CACHE
physical id	: 0
siblings	: $NPROC
core id		: $i
cpu cores	: $NPROC
apicid		: $i
initial apicid	: $i
fpu		: yes
fpu_exception	: yes
cpuid level	: 13
wp		: yes
flags		: $FLAGS
bugs		: spectre_v1 spectre_v2 spec_store_bypass
bogomips	: 6589.37
clflush size	: 64
cache_alignment	: 64
address sizes	: 46 bits physical, 48 bits virtual
power management:

EOF
        i=$((i + 1))
    done
    mount -n --bind "$CPUINFO_FILE" "${LXC_ROOTFS}/proc/cpuinfo" 2>/dev/null || true
fi
SYS_CPU_DIR="${LXC_ROOTFS}/sys/devices/system/cpu"
if [ -d "$SYS_CPU_DIR" ]; then
    if [ "$NPROC" -eq 1 ]; then
        CPULIST="0"
    else
        CPULIST="0-$((NPROC - 1))"
    fi
    echo "$CPULIST" > "${TMP_DIR}/present"
    mount -n --bind "${TMP_DIR}/present" "${SYS_CPU_DIR}/present" 2>/dev/null || true
    echo "$CPULIST" > "${TMP_DIR}/online"
    mount -n --bind "${TMP_DIR}/online" "${SYS_CPU_DIR}/online" 2>/dev/null || true
    echo "$((NPROC - 1))" > "${TMP_DIR}/kernel_max"
    mount -n --bind "${TMP_DIR}/kernel_max" "${SYS_CPU_DIR}/kernel_max" 2>/dev/null || true
fi
NODE_DIR="${LXC_ROOTFS}/sys/devices/system/node"
if [ -d "${NODE_DIR}/node0" ]; then
    echo "$CPULIST" > "${TMP_DIR}/node0_cpulist"
    mount -n --bind "${TMP_DIR}/node0_cpulist" "${NODE_DIR}/node0/cpulist" 2>/dev/null || true
fi
exit 0
WRAPPER
chmod 755 /opt/incus-lxcfs-mount-wrapper.sh
ok "Mount wrapper installed"

step "5/11 — Verify Incus config"

# Install btrfs-progs for dedicated disk quotas (fallback to dir if loop unavailable)
apt-get install -y btrfs-progs 2>/dev/null || true

# Create default storage pool — try btrfs first (dedicated disk per VPS)
if timeout 10 incus storage show default >/dev/null 2>&1; then
    POOL_DRIVER=$(incus storage show default 2>/dev/null | grep "driver:" | awk "{print \$2}")
    ok "Storage pool 'default' already exists (driver: $POOL_DRIVER)"
else
    echo "  Creating storage pool 'default'..."
    if timeout 60 incus storage create default btrfs size=100GB 2>/dev/null; then
        ok "Storage pool 'default' created (btrfs — dedicated disk quotas)"
    else
        echo "  btrfs pool failed (loop devices not available in Docker)."
        echo "  Falling back to dir pool (df -h will show host overlay space)."
        echo "  To enable dedicated disk: restart Docker with --privileged"
        echo "    docker run --privileged ..."
        POOL_OUT=$(timeout 60 incus storage create default dir 2>&1) || true
        if ! timeout 10 incus storage show default >/dev/null 2>&1; then
            echo "  WARNING: storage create failed: $POOL_OUT"
            echo "  You can create it later with: incus storage create default dir"
        fi
        ok "Storage pool handled (dir — host overlay visible inside VPS)"
    fi
fi

# Create incusbr0 bridge network if missing
if ! timeout 10 incus network list 2>/dev/null | grep -q "incusbr0"; then
    echo "  Creating bridge network 'incusbr0' (10.132.115.1/24)..."
    timeout 30 incus network create incusbr0 \
        --type=bridge \
        ipv4.address=10.132.115.1/24 \
        ipv4.nat=true \
        ipv6.address=none 2>&1 || {
        echo "  'incus network create' failed, checking if network exists anyway..."
        timeout 10 incus network list 2>/dev/null | grep -q "incusbr0" || echo "  WARNING: network not created"
    }
    ok "Bridge network 'incusbr0' created"
else
    ok "Bridge network 'incusbr0' already exists"
fi

# Ensure default profile has root disk and eth0 nic + required security settings
HAS_ROOT=false; HAS_ETH0=false
timeout 10 incus profile device list default 2>/dev/null | grep -q "root" && HAS_ROOT=true
timeout 10 incus profile device list default 2>/dev/null | grep -q "eth0" && HAS_ETH0=true
if [ "$HAS_ROOT" = false ] || [ "$HAS_ETH0" = false ]; then
    echo "  Configuring default profile..."
    if [ "$HAS_ROOT" = false ]; then
        timeout 10 incus profile device add default root disk path=/ pool=default 2>/dev/null || true
    fi
    if [ "$HAS_ETH0" = false ]; then
        timeout 10 incus profile device add default eth0 nic name=eth0 network=incusbr0 2>/dev/null || true
    fi
fi
# Set required security settings for nested VPS containers
timeout 10 incus profile set default security.privileged=true 2>/dev/null || true
timeout 10 incus profile set default security.nesting=true 2>/dev/null || true
# Set raw.lxc with apparmor profile and mount wrapper for cpuinfo fix
timeout 10 incus profile set default raw.lxc "lxc.apparmor.profile=unconfined
lxc.hook.mount = /opt/incus-lxcfs-mount-wrapper.sh" 2>/dev/null || true
ok "Default profile configured (privileged+nesting, cpuinfo mount wrapper)"

echo ""
echo "  Storage pools:"
timeout 10 incus storage list 2>/dev/null | sed 's/^/    /'
echo "  Networks:"
timeout 10 incus network list 2>/dev/null | sed 's/^/    /'

step "6/11 — Pre-download Ubuntu Incus images"
for ver in 22.04 24.04 26.04; do
    if timeout 10 incus image list 2>/dev/null | grep -q "$ver"; then
        ok "Ubuntu $ver already cached"
    else
        echo "  Downloading Ubuntu $ver (this may take a minute)..."
        timeout 300 incus image copy images:ubuntu/$ver local: --alias "$ver" --auto-update 2>&1 || \
        echo "  WARNING: Could not pre-download Ubuntu $ver (will pull on demand)"
    fi
done
echo "  Cached images:"
timeout 15 incus image list 2>/dev/null | sed 's/^/    /' || echo "  (unavailable)"
ok "Incus images ready"

step "7/11 — Python 3.10"
NEED_INSTALL=false
echo "  Checking python3.10..."
command -v python3.10 || NEED_INSTALL=true
echo "  Checking python3.10 -m venv..."
python3.10 -m venv --help >/dev/null 2>&1 || NEED_INSTALL=true
echo "  Checking python3.10 -m ensurepip..."
python3.10 -m ensurepip --version >/dev/null 2>&1 || NEED_INSTALL=true
echo "  Checking python3.10 distutils..."
python3.10 -c "import distutils" >/dev/null 2>&1 || NEED_INSTALL=true

if [ "$NEED_INSTALL" = true ]; then
    echo "  Python 3.10 incomplete, installing from deadsnakes PPA..."
    add-apt-repository ppa:deadsnakes/ppa -y
    apt-get update
    apt-get install -y python3.10 python3.10-venv python3.10-distutils \
                       python3-pip-whl python3-setuptools-whl
fi
echo "  Python version: $(python3.10 --version)"
ok "Python 3.10 ready"

step "8/11 — Install pip for Python 3.10"
echo "  Downloading get-pip.py..."
curl -sS https://bootstrap.pypa.io/get-pip.py | python3.10
echo "  Pip version: $(python3.10 -m pip --version)"
ok "pip installed"

step "9/11 — Setup virtual environment"
echo "  Creating venv..."
python3.10 -m venv venv
source venv/bin/activate
echo "  Python: $(which python)"
echo "  Pip:    $(which pip)"
ok "Virtual environment created"

step "10/11 — Python packages"
echo "  Upgrading pip..."
pip install --upgrade pip
echo "  Installing requirements.txt..."
pip install -r requirements.txt
echo "  Installing node_requirements.txt..."
pip install -r node_requirements.txt
echo "  Installed packages:"
pip list --format=columns
ok "Python packages installed"

step "11/11 — Setup directories & database"
echo "  Creating static/uploads..."
mkdir -p static/uploads
echo "  Initializing database..."
venv/bin/python -c "import app; app.init_db(); print('Database initialized')"
echo "  Database files: $(ls -la database.db 2>/dev/null || echo 'database.db created')"
ok "Database ready"

echo ""
echo "  Incus: $(timeout 5 incus version 2>/dev/null | head -1 || echo 'unknown')"
echo ""
echo "  Storage pools:"
timeout 10 incus storage list 2>/dev/null | sed 's/^/    /' || echo "    (unavailable)"
echo ""
echo "  Network:"
timeout 10 incus network list 2>/dev/null | sed 's/^/    /' || echo "    (unavailable)"
echo ""
echo "  Images:"
timeout 10 incus image list 2>/dev/null | sed 's/^/    /' || echo "    (unavailable)"
echo ""
timeout 5 incus info 2>/dev/null | grep -E "Kernel|Uptime|Incus" | sed 's/^/  /' || true
ok "All checks passed"

echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}   Omega Panel — Setup Complete${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
echo "  Admin login:"
echo "    Username: admin"
echo "    Password: admin123"
echo ""
echo "  Start panel:"
echo "    cd Omega-Panel-V3-Incus"
echo "    source venv/bin/activate"
echo "    python app.py"
echo ""
echo "  Start node agent (on each node):"
echo "    cd Omega-Panel-V3-Incus"
echo "    source venv/bin/activate"
echo "    python node.py"
echo ""
echo "  Default VPS OS options:"
echo "    Ubuntu 22.04, 24.04, 26.04"
echo ""
echo -e "${GREEN}============================================${NC}"
