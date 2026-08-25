#!/bin/bash
set -e

VPS_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$VPS_DIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; exit 1; }
step() { echo -e "\n${CYAN}==> $1${NC}"; }

# ------------------------------------------------------------
# Basic checks
# ------------------------------------------------------------

if [ "$(id -u)" -ne 0 ]; then
    fail "Run as root: sudo bash setup.sh"
fi

if [ ! -f /etc/almalinux-release ]; then
    warn "This script is intended for AlmaLinux 9."
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "  Detected OS: ${PRETTY_NAME:-unknown}"
    fi
fi

if [ -f /etc/os-release ]; then
    . /etc/os-release
fi

RHEL_MAJOR="$(rpm -E '%{rhel}' 2>/dev/null || echo 0)"

if [ "$RHEL_MAJOR" != "9" ]; then
    fail "This script targets AlmaLinux/RHEL 9. Detected RHEL major version: $RHEL_MAJOR"
fi

ARCH="$(uname -m)"

echo ""
echo "============================================"
echo "   Omega Panel — AlmaLinux 9 Setup"
echo "============================================"
echo ""
echo "  OS:       ${PRETTY_NAME:-unknown}"
echo "  Arch:     $ARCH"
echo "  Directory: $VPS_DIR"
echo ""

# ------------------------------------------------------------
# STEP 1
# ------------------------------------------------------------

step "1/11 — System packages"

echo "  Updating DNF metadata..."
dnf makecache

echo "  Installing system packages..."

dnf install -y \
    curl \
    wget \
    gnupg2 \
    ca-certificates \
    socat \
    jq \
    tar \
    gzip \
    unzip \
    git \
    rsync \
    findutils \
    procps-ng \
    util-linux \
    which \
    sudo \
    openssh-clients \
    policycoreutils \
    policycoreutils-python-utils \
    dnf-plugins-core \
    gcc \
    gcc-c++ \
    make \
    patch \
    bzip2 \
    bzip2-devel \
    xz \
    xz-devel \
    zlib \
    zlib-devel \
    readline \
    readline-devel \
    sqlite \
    sqlite-devel \
    libffi \
    libffi-devel \
    openssl \
    openssl-devel \
    tk \
    tk-devel \
    ncurses \
    ncurses-devel \
    gdbm \
    gdbm-devel \
    uuid \
    uuid-devel \
    libuuid \
    libuuid-devel \
    btrfs-progs

ok "System packages installed"

# ------------------------------------------------------------
# STEP 2
# ------------------------------------------------------------

step "2/11 — Install Incus"

INCUS_OK=false

# Check whether Incus socket already exists.
if [ -S /var/lib/incus/unix.socket ]; then
    INCUS_OK=true
fi

# Check whether incus command exists.
if [ "$INCUS_OK" = false ] && command -v incus >/dev/null 2>&1; then
    INCUS_OK=true
fi

# Check whether incusd service exists.
if systemctl list-unit-files 2>/dev/null | grep -q '^incus\.service'; then
    INCUS_OK=true
fi

if [ "$INCUS_OK" = true ]; then
    ok "Incus already installed"
else
    echo "  Installing EPEL..."
    dnf install -y epel-release

    echo "  Enabling CRB..."
    if command -v crb >/dev/null 2>&1; then
        crb enable || true
    else
        dnf config-manager --set-enabled crb || true
    fi

    echo "  Enabling Incus COPR repository..."
    dnf copr enable -y neelc/incus

    echo "  Installing Incus..."
    dnf install -y \
        incus \
        incus-tools \
        incus-selinux

    ok "Incus installed"
fi

# Install supporting packages even if Incus was already present.
dnf install -y \
    epel-release \
    incus-tools \
    incus-selinux \
    btrfs-progs \
    fuse3 \
    fuse3-libs \
    lxcfs 2>/dev/null || true

# Remove old custom hook if it exists.
rm -f /opt/incus-lxcfs-mount.sh

# ------------------------------------------------------------
# QEMU compatibility
# ------------------------------------------------------------

echo "  Checking QEMU compatibility..."

if [ -x /usr/libexec/qemu-kvm ]; then
    mkdir -p /usr/local/bin
    ln -sf /usr/libexec/qemu-kvm /usr/local/bin/qemu-system-x86_64
    ok "QEMU compatibility symlink installed"
else
    warn "qemu-kvm binary not found; VM support may be unavailable"
fi

# ------------------------------------------------------------
# Start Incus
# ------------------------------------------------------------

echo "  Enabling Incus service..."

systemctl daemon-reload || true

if systemctl list-unit-files 2>/dev/null | grep -q '^incus\.service'; then
    systemctl enable incus.service || true
    systemctl start incus.service || true
elif systemctl list-unit-files 2>/dev/null | grep -q '^incusd\.service'; then
    systemctl enable incusd.service || true
    systemctl start incusd.service || true
else
    warn "Could not find incus/incusd systemd service"
fi

# ------------------------------------------------------------
# STEP 3
# ------------------------------------------------------------

step "3/11 — Initialize Incus"

echo "  Waiting for Incus socket..."

for i in $(seq 1 60); do
    if [ -S /var/lib/incus/unix.socket ]; then
        break
    fi

    sleep 1
done

if [ ! -S /var/lib/incus/unix.socket ]; then
    echo ""
    echo "  Incus service status:"
    systemctl status incus --no-pager 2>/dev/null || \
    systemctl status incusd --no-pager 2>/dev/null || true

    fail "Incus socket not found at /var/lib/incus/unix.socket"
fi

echo "  Incus socket ready."

echo "  Waiting for Incus daemon..."

INCUS_READY=false

for i in $(seq 1 30); do
    if timeout 5 incus info >/dev/null 2>&1; then
        INCUS_READY=true
        echo "  Incus daemon ready after ~${i}s"
        break
    fi

    if [ "$i" -eq 20 ]; then
        echo "  (still waiting... incus not responding yet)"
    fi

    sleep 2
done

# If daemon isn't initialized, attempt automatic initialization.
if [ "$INCUS_READY" = false ]; then
    echo "  Attempting automatic Incus initialization..."

    if timeout 30 incus admin init --auto 2>/dev/null; then
        INCUS_READY=true
        ok "Incus initialized automatically"
    else
        echo "  Automatic initialization failed."
        echo "  Trying incus admin init again..."

        if timeout 30 incus admin init --auto; then
            INCUS_READY=true
        fi
    fi
fi

if [ "$INCUS_READY" = false ]; then
    fail "Incus daemon did not become ready"
fi

ok "Incus daemon ready"

# ------------------------------------------------------------
# STEP 4
# ------------------------------------------------------------

step "4/11 — Setup LXCFS (correct container resource views)"

echo "  Installing lxcfs..."

dnf install -y lxcfs 2>/dev/null || true

# AlmaLinux/RHEL systemd may refuse to start lxcfs inside Docker
# because of ConditionVirtualization.
mkdir -p /etc/systemd/system/lxcfs.service.d
mkdir -p /etc/systemd/system/incus-lxcfs.service.d

cat > /etc/systemd/system/lxcfs.service.d/override.conf <<'OVERRIDE'
[Unit]
ConditionVirtualization=
OVERRIDE

cat > /etc/systemd/system/incus-lxcfs.service.d/override.conf <<'OVERRIDE'
[Unit]
ConditionVirtualization=
OVERRIDE

systemctl daemon-reload || true

# Stop stale processes/mounts.
pkill -9 lxcfs 2>/dev/null || true

sleep 1

umount -l /var/lib/lxcfs 2>/dev/null || true
umount -l /var/lib/incus-lxcfs 2>/dev/null || true

rm -rf /var/lib/incus-lxcfs 2>/dev/null || true
rm -rf /var/lib/lxcfs 2>/dev/null || true

mkdir -p /var/lib/incus-lxcfs

LXCFS_STARTED=false

# Try Incus-specific service first.
if systemctl list-unit-files 2>/dev/null | grep -q '^incus-lxcfs\.service'; then
    systemctl enable incus-lxcfs.service 2>/dev/null || true
    systemctl start incus-lxcfs.service 2>/dev/null || true
    sleep 2

    if mount | grep -q "lxcfs.*incus-lxcfs"; then
        LXCFS_STARTED=true
    fi
fi

# Try regular lxcfs service.
if [ "$LXCFS_STARTED" = false ]; then
    if systemctl list-unit-files 2>/dev/null | grep -q '^lxcfs\.service'; then
        systemctl enable lxcfs.service 2>/dev/null || true
        systemctl start lxcfs.service 2>/dev/null || true
        sleep 2
    fi

    if mount | grep -q "lxcfs"; then
        LXCFS_STARTED=true
    fi
fi

# Fallback to direct lxcfs startup.
if [ "$LXCFS_STARTED" = false ]; then
    echo "  Trying fallback: starting lxcfs directly..."

    mkdir -p /var/lib/incus-lxcfs

    if command -v lxcfs >/dev/null 2>&1; then
        nohup lxcfs /var/lib/incus-lxcfs \
            > /var/log/lxcfs.log 2>&1 &

        disown || true

        sleep 3

        if mount | grep -q "lxcfs.*incus-lxcfs"; then
            LXCFS_STARTED=true
        fi
    fi
fi

if [ "$LXCFS_STARTED" = true ]; then
    ok "LXCFS running at /var/lib/incus-lxcfs"

    echo "  Memory from lxcfs:"
    cat /var/lib/incus-lxcfs/proc/meminfo 2>/dev/null | head -1 || true
else
    warn "LXCFS could not be mounted"
    echo "  Containers may show host resource totals."
    echo "  This is common when Incus is itself running inside Docker."
fi

# ------------------------------------------------------------
# STEP 4b
# ------------------------------------------------------------

step "4b/11 — Install lxcfs mount wrapper for cpuinfo"

cat > /opt/incus-lxcfs-mount-wrapper.sh <<'WRAPPER'
#!/bin/sh

# Wrapper around Incus/LXCFS mount handling.
# Fixes /proc/cpuinfo and /sys/devices/system/cpu
# when LXCFS returns empty/host data in nested environments.

HOOK="/opt/incus/share/lxcfs/lxc.mount.hook"

if [ -x "$HOOK" ]; then
    "$HOOK" "$@"
else
    # Some RPM layouts place the hook elsewhere.
    ALT_HOOK="$(command -v lxc.mount.hook 2>/dev/null || true)"

    if [ -n "$ALT_HOOK" ] && [ -x "$ALT_HOOK" ]; then
        "$ALT_HOOK" "$@"
    fi
fi

LXC_ROOTFS="${LXC_ROOTFS_MOUNT}"

if [ -z "$LXC_ROOTFS" ] || [ ! -d "$LXC_ROOTFS" ]; then
    exit 0
fi

NPROC=1

BACKUP_YAML="/var/lib/incus/containers/${LXC_NAME}/backup.yaml"

if [ -f "$BACKUP_YAML" ]; then
    CONFIG_NPROC=$(
        grep -A2 'limits.cpu' "$BACKUP_YAML" 2>/dev/null |
        head -1 |
        sed 's/.*: *"\(.*\)"/\1/' |
        sed 's/[^0-9]//g'
    )

    if [ -n "$CONFIG_NPROC" ] && [ "$CONFIG_NPROC" -gt 0 ] 2>/dev/null; then
        NPROC="$CONFIG_NPROC"
    fi
fi

TMP_DIR="${LXC_ROOTFS}/dev/.lxc-cpuinfo"

mkdir -p "$TMP_DIR" 2>/dev/null || true

mount -t tmpfs tmpfs "$TMP_DIR" 2>/dev/null || true

CPUINFO_EMPTY=false

if [ -f "${LXC_ROOTFS}/proc/cpuinfo" ]; then
    READ_BYTES=$(
        head -c 1 "${LXC_ROOTFS}/proc/cpuinfo" 2>/dev/null |
        wc -c
    )

    if [ "$READ_BYTES" = "0" ]; then
        CPUINFO_EMPTY=true
    fi
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

    mount -n --bind \
        "$CPUINFO_FILE" \
        "${LXC_ROOTFS}/proc/cpuinfo" \
        2>/dev/null || true
fi

SYS_CPU_DIR="${LXC_ROOTFS}/sys/devices/system/cpu"

if [ -d "$SYS_CPU_DIR" ]; then

    if [ "$NPROC" -eq 1 ]; then
        CPULIST="0"
    else
        CPULIST="0-$((NPROC - 1))"
    fi

    echo "$CPULIST" > "${TMP_DIR}/present"

    mount -n --bind \
        "${TMP_DIR}/present" \
        "${SYS_CPU_DIR}/present" \
        2>/dev/null || true

    echo "$CPULIST" > "${TMP_DIR}/online"

    mount -n --bind \
        "${TMP_DIR}/online" \
        "${SYS_CPU_DIR}/online" \
        2>/dev/null || true

    echo "$((NPROC - 1))" > "${TMP_DIR}/kernel_max"

    mount -n --bind \
        "${TMP_DIR}/kernel_max" \
        "${SYS_CPU_DIR}/kernel_max" \
        2>/dev/null || true
fi

NODE_DIR="${LXC_ROOTFS}/sys/devices/system/node"

if [ -d "${NODE_DIR}/node0" ]; then

    echo "$CPULIST" > "${TMP_DIR}/node0_cpulist"

    mount -n --bind \
        "${TMP_DIR}/node0_cpulist" \
        "${NODE_DIR}/node0/cpulist" \
        2>/dev/null || true
fi

exit 0
WRAPPER

chmod 755 /opt/incus-lxcfs-mount-wrapper.sh

ok "Mount wrapper installed"

# ------------------------------------------------------------
# STEP 5
# ------------------------------------------------------------

step "5/11 — Verify Incus config"

# ------------------------------------------------------------
# Storage
# ------------------------------------------------------------

echo "  Checking storage pool..."

if timeout 10 incus storage show default >/dev/null 2>&1; then

    POOL_DRIVER=$(
        incus storage show default 2>/dev/null |
        grep "^driver:" |
        awk '{print $2}'
    )

    ok "Storage pool 'default' already exists (driver: $POOL_DRIVER)"

else

    echo "  Creating storage pool 'default'..."

    if timeout 60 incus storage create default btrfs size=100GB 2>/dev/null; then

        ok "Storage pool 'default' created (btrfs)"

    else

        echo "  btrfs pool failed."

        echo "  This commonly happens when Incus is running inside Docker"
        echo "  without loop/block-device privileges."

        echo "  Falling back to directory storage..."

        POOL_OUT=$(
            timeout 60 incus storage create default dir 2>&1
        ) || true

        if ! timeout 10 incus storage show default >/dev/null 2>&1; then
            echo "  WARNING: storage creation failed:"
            echo "$POOL_OUT"
            echo ""
            echo "  You can create it later with:"
            echo "    incus storage create default dir"
        else
            ok "Storage pool 'default' created (dir)"
        fi
    fi
fi

# ------------------------------------------------------------
# Network
# ------------------------------------------------------------

echo "  Checking incusbr0 network..."

if ! timeout 10 incus network list 2>/dev/null |
    grep -q "incusbr0"; then

    echo "  Creating bridge network 'incusbr0'..."

    timeout 30 incus network create incusbr0 \
        --type=bridge \
        ipv4.address=10.132.115.1/24 \
        ipv4.nat=true \
        ipv6.address=none \
        2>&1 || {

        echo "  Network creation failed."
        echo "  Checking whether network exists anyway..."

        timeout 10 incus network list 2>/dev/null |
            grep -q "incusbr0" ||
            echo "  WARNING: network was not created"
    }

    if timeout 10 incus network list 2>/dev/null |
        grep -q "incusbr0"; then
        ok "Bridge network 'incusbr0' created"
    fi

else

    ok "Bridge network 'incusbr0' already exists"

fi

# ------------------------------------------------------------
# Default profile
# ------------------------------------------------------------

echo "  Checking default profile..."

HAS_ROOT=false
HAS_ETH0=false

if timeout 10 incus profile device list default 2>/dev/null |
    grep -q "^root"; then
    HAS_ROOT=true
fi

if timeout 10 incus profile device list default 2>/dev/null |
    grep -q "^eth0"; then
    HAS_ETH0=true
fi

if [ "$HAS_ROOT" = false ] || [ "$HAS_ETH0" = false ]; then

    echo "  Configuring default profile..."

    if [ "$HAS_ROOT" = false ]; then
        timeout 10 incus profile device add \
            default \
            root \
            disk \
            path=/ \
            pool=default \
            2>/dev/null || true
    fi

    if [ "$HAS_ETH0" = false ]; then
        timeout 10 incus profile device add \
            default \
            eth0 \
            nic \
            name=eth0 \
            network=incusbr0 \
            2>/dev/null || true
    fi
fi

# ------------------------------------------------------------
# Security settings
# ------------------------------------------------------------

echo "  Configuring nested-container settings..."

timeout 10 incus profile set \
    default \
    security.privileged=true \
    2>/dev/null || true

timeout 10 incus profile set \
    default \
    security.nesting=true \
    2>/dev/null || true

# AlmaLinux uses SELinux. The Incus SELinux package should provide
# the required policy. We deliberately do not disable SELinux globally.

# Raw LXC configuration.
RAW_LXC="lxc.apparmor.profile=unconfined"

if [ -x /opt/incus/share/lxcfs/lxc.mount.hook ]; then
    RAW_LXC="${RAW_LXC}
lxc.hook.mount = /opt/incus-lxcfs-mount-wrapper.sh"
fi

timeout 10 incus profile set \
    default \
    raw.lxc "$RAW_LXC" \
    2>/dev/null || true

ok "Default profile configured"

echo ""
echo "  Storage pools:"
timeout 10 incus storage list 2>/dev/null |
    sed 's/^/    /' || true

echo ""
echo "  Networks:"
timeout 10 incus network list 2>/dev/null |
    sed 's/^/    /' || true

# ------------------------------------------------------------
# STEP 6
# ------------------------------------------------------------

step "6/11 — Pre-download Ubuntu Incus images"

for ver in 22.04 24.04 26.04; do

    if timeout 10 incus image list 2>/dev/null |
        grep -q "$ver"; then

        ok "Ubuntu $ver already cached"

    else

        echo "  Downloading Ubuntu $ver..."
        echo "  This may take a minute..."

        timeout 300 \
            incus image copy \
            images:ubuntu/$ver \
            local: \
            --alias "$ver" \
            --auto-update \
            2>&1 || {

            warn "Could not pre-download Ubuntu $ver"
            echo "  It will be pulled on demand."
        }
    fi
done

echo ""
echo "  Cached images:"

timeout 15 incus image list 2>/dev/null |
    sed 's/^/    /' ||
    echo "    (unavailable)"

ok "Incus images ready"

# ------------------------------------------------------------
# STEP 7
# ------------------------------------------------------------

step "7/11 — Python 3.10"

PYTHON_VERSION="3.10.18"
PYTHON_PREFIX="/usr/local/python-3.10"
PYTHON_BIN="${PYTHON_PREFIX}/bin/python3.10"

NEED_PYTHON=false

if [ -x "$PYTHON_BIN" ]; then

    INSTALLED_PYTHON="$("$PYTHON_BIN" --version 2>&1 || true)"

    if echo "$INSTALLED_PYTHON" | grep -q "Python 3.10"; then
        ok "Python 3.10 already installed"
    else
        NEED_PYTHON=true
    fi

else
    NEED_PYTHON=true
fi

if [ "$NEED_PYTHON" = true ]; then

    echo "  AlmaLinux 9 does not provide the requested Python 3.10"
    echo "  as the standard system Python."
    echo "  Building Python ${PYTHON_VERSION} under ${PYTHON_PREFIX}..."

    BUILD_DIR="/usr/local/src/python-${PYTHON_VERSION}"

    rm -rf "$BUILD_DIR"

    mkdir -p /usr/local/src

    cd /usr/local/src

    echo "  Downloading Python ${PYTHON_VERSION}..."

    curl -fL \
        "https://www.python.org/ftp/python/${PYTHON_VERSION}/Python-${PYTHON_VERSION}.tgz" \
        -o "Python-${PYTHON_VERSION}.tgz"

    tar -xzf "Python-${PYTHON_VERSION}.tgz"

    mv \
        "Python-${PYTHON_VERSION}" \
        "$BUILD_DIR"

    cd "$BUILD_DIR"

    echo "  Configuring Python..."

    ./configure \
        --prefix="$PYTHON_PREFIX" \
        --enable-optimizations \
        --with-ensurepip=install

    echo "  Compiling Python..."

    CPU_COUNT="$(nproc 2>/dev/null || echo 2)"

    make -j"$CPU_COUNT"

    echo "  Installing Python..."

    make altinstall

    if [ ! -x "$PYTHON_BIN" ]; then
        fail "Python 3.10 installation failed"
    fi

    # Convenience symlink.
    ln -sf "$PYTHON_BIN" /usr/local/bin/python3.10

    ok "Python 3.10 installed"
fi

echo "  Python version:"
"$PYTHON_BIN" --version

echo "  Checking venv..."
"$PYTHON_BIN" -m venv --help >/dev/null 2>&1 ||
    fail "Python 3.10 venv module unavailable"

echo "  Checking ensurepip..."
"$PYTHON_BIN" -m ensurepip --version >/dev/null 2>&1 ||
    fail "Python 3.10 ensurepip unavailable"

echo "  Checking distutils..."

"$PYTHON_BIN" -c "import distutils" >/dev/null 2>&1 || {
    warn "distutils unavailable; modern Python packages should still work"
}

ok "Python 3.10 ready"

# ------------------------------------------------------------
# STEP 8
# ------------------------------------------------------------

step "8/11 — Install pip for Python 3.10"

echo "  Updating pip..."

"$PYTHON_BIN" -m ensurepip --upgrade

"$PYTHON_BIN" -m pip install \
    --upgrade \
    pip \
    setuptools \
    wheel

echo "  Pip version:"
"$PYTHON_BIN" -m pip --version

ok "pip installed"

# ------------------------------------------------------------
# STEP 9
# ------------------------------------------------------------

step "9/11 — Setup virtual environment"

echo "  Creating venv..."

rm -rf venv

"$PYTHON_BIN" -m venv venv

if [ ! -x venv/bin/python ]; then
    fail "Virtual environment creation failed"
fi

source venv/bin/activate

echo "  Python: $(which python)"
echo "  Pip:    $(which pip)"

python --version
pip --version

ok "Virtual environment created"

# ------------------------------------------------------------
# STEP 10
# ------------------------------------------------------------

step "10/11 — Python packages"

if [ ! -f requirements.txt ]; then
    warn "requirements.txt not found"
else

    echo "  Upgrading pip..."

    pip install --upgrade pip setuptools wheel

    echo "  Installing requirements.txt..."

    pip install -r requirements.txt
fi

if [ -f node_requirements.txt ]; then

    echo "  Installing node_requirements.txt..."

    pip install -r node_requirements.txt

else

    warn "node_requirements.txt not found"

fi

echo ""
echo "  Installed packages:"

pip list --format=columns

ok "Python packages installed"

deactivate

# ------------------------------------------------------------
# STEP 11
# ------------------------------------------------------------

step "11/11 — Setup directories & database"

echo "  Creating static/uploads..."

mkdir -p static/uploads

echo "  Initializing database..."

if [ -x venv/bin/python ]; then

    venv/bin/python -c \
        "import app; app.init_db(); print('Database initialized')"

else

    fail "venv/bin/python not found"

fi

echo ""
echo "  Database files:"

ls -la database.db 2>/dev/null ||
    echo "    database.db created"

ok "Database ready"

# ------------------------------------------------------------
# Final verification
# ------------------------------------------------------------

echo ""
echo "============================================"
echo "   Final verification"
echo "============================================"
echo ""

echo "  OS:"
echo "    ${PRETTY_NAME:-unknown}"

echo ""
echo "  Python:"
"$PYTHON_BIN" --version 2>/dev/null |
    sed 's/^/    /' || true

echo ""
echo "  Incus:"

timeout 5 incus version 2>/dev/null |
    head -1 |
    sed 's/^/    /' ||
    echo "    unknown"

echo ""
echo "  Incus service:"

if systemctl is-active --quiet incus 2>/dev/null; then
    echo "    active"
elif systemctl is-active --quiet incusd 2>/dev/null; then
    echo "    active"
else
    echo "    not active"
fi

echo ""
echo "  Storage pools:"

timeout 10 incus storage list 2>/dev/null |
    sed 's/^/    /' ||
    echo "    (unavailable)"

echo ""
echo "  Network:"

timeout 10 incus network list 2>/dev/null |
    sed 's/^/    /' ||
    echo "    (unavailable)"

echo ""
echo "  Images:"

timeout 10 incus image list 2>/dev/null |
    sed 's/^/    /' ||
    echo "    (unavailable)"

echo ""
echo "  Incus info:"

timeout 5 incus info 2>/dev/null |
    grep -E "Kernel|Uptime|Incus" |
    sed 's/^/    /' ||
    true

echo ""
echo "  LXCFS:"

if mount | grep -q "lxcfs"; then
    echo "    mounted"
else
    echo "    not mounted"
fi

# ------------------------------------------------------------
# SELinux information
# ------------------------------------------------------------

echo ""
echo "  SELinux:"

if command -v getenforce >/dev/null 2>&1; then
    echo "    $(getenforce)"
else
    echo "    unavailable"
fi

# ------------------------------------------------------------
# Final output
# ------------------------------------------------------------

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

echo "  Start node agent:"
echo "    cd Omega-Panel-V3-Incus"
echo "    source venv/bin/activate"
echo "    python node.py"
echo ""

echo "  Default VPS OS options:"
echo "    Ubuntu 22.04"
echo "    Ubuntu 24.04"
echo "    Ubuntu 26.04"
echo ""

echo "  Incus:"
echo "    $(timeout 5 incus version 2>/dev/null | head -1 || echo 'unknown')"
echo ""

echo -e "${GREEN}============================================${NC}"
echo ""
echo -e "${GREEN}[OK] All checks completed${NC}"
