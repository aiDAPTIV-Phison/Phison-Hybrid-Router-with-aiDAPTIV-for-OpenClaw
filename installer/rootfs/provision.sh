#!/usr/bin/env bash
# Provision a vanilla Ubuntu 24.04 WSL rootfs into the shippable
# `aidaptivclaw` rootfs. Runs as root inside the throwaway build distro
# orchestrated by `scripts/build-rootfs.ps1`.
#
# Inputs (pre-staged by the orchestrator):
#   /tmp/openclaw-src/         OpenClaw source tree (from `git archive HEAD`)
#   /tmp/rootfs-config/        wsl.conf + openclaw-gateway.service
#
# Environment overrides:
#   NODE_VERSION (default: 22.11.0)
#   PNPM_VERSION (default: 9.12.0)
set -euo pipefail

NODE_VERSION="${NODE_VERSION:-22.11.0}"
PNPM_VERSION="${PNPM_VERSION:-9.12.0}"

export DEBIAN_FRONTEND=noninteractive

log() { printf '[provision] %s\n' "$*"; }

# 1. Base packages. systemd is mandatory because wsl.conf will set
#    [boot] systemd=true, and the gateway runs as a systemd unit.
log "[1/8] Installing base packages..."
apt-get update
apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg git python3 build-essential \
    dbus systemd systemd-sysv \
    sudo locales tzdata
locale-gen en_US.UTF-8
rm -rf /var/lib/apt/lists/*

# 2. Node.js 22 LTS. Use the official binary tarball rather than NodeSource
#    so we don't pull in another apt repo + GPG key.
log "[2/8] Installing Node.js ${NODE_VERSION}..."
mkdir -p /opt/node
curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" \
    | tar -xJ --strip-components=1 -C /opt/node
ln -sf /opt/node/bin/node /usr/local/bin/node
ln -sf /opt/node/bin/npm  /usr/local/bin/npm
ln -sf /opt/node/bin/npx  /usr/local/bin/npx

# 3. pnpm via standalone binary. Avoids `npm i -g` and pins the version.
log "[3/8] Installing pnpm ${PNPM_VERSION}..."
mkdir -p /opt/pnpm
curl -fsSL "https://github.com/pnpm/pnpm/releases/download/v${PNPM_VERSION}/pnpm-linux-x64" \
    -o /opt/pnpm/pnpm
chmod +x /opt/pnpm/pnpm
ln -sf /opt/pnpm/pnpm /usr/local/bin/pnpm

# 4. Non-root runtime user. uid 1000 is conventional for the first user.
#    nologin shell + no sudo group => process cannot escalate even if
#    compromised, even if it manages to spawn a shell.
log "[4/8] Creating openclaw user..."
useradd --create-home --uid 1000 --shell /usr/sbin/nologin openclaw

# 5. Build OpenClaw. We build as root for simplicity and chown to openclaw
#    at the end — building as the runtime user would require pre-creating
#    a sudo-less writable scratch area, which adds complexity for no gain
#    (build artifacts are shipped read-only).
log "[5/8] Building OpenClaw..."
test -d /tmp/openclaw-src || {
    echo "ERROR: /tmp/openclaw-src missing — orchestrator must stage source first" >&2
    exit 1
}
cd /tmp/openclaw-src
pnpm install --ignore-scripts
# Native modules used by OpenClaw — explicit rebuild keeps the install
# step lean (--ignore-scripts above) while still producing working binaries.
pnpm rebuild esbuild sharp koffi protobufjs
pnpm build:docker
pnpm ui:build

mkdir -p /opt/openclaw
cp -a /tmp/openclaw-src/. /opt/openclaw/
chown -R openclaw:openclaw /opt/openclaw
rm -rf /tmp/openclaw-src

# 6. Install WSL boot config + systemd unit (created in Task 1.2).
log "[6/8] Installing wsl.conf and systemd unit..."
install -m 0644 /tmp/rootfs-config/wsl.conf /etc/wsl.conf
install -m 0644 /tmp/rootfs-config/openclaw-gateway.service \
    /etc/systemd/system/openclaw-gateway.service
systemctl enable openclaw-gateway.service

# 7. Pre-create writable allowlist directories matching ReadWritePaths=
#    in the systemd unit. Doing this at provision time avoids first-boot
#    races where the gateway starts before /home is fully provisioned.
log "[7/8] Creating writable allowlist directories..."
install -d -m 0755 -o openclaw -g openclaw \
    /home/openclaw/workspace \
    /home/openclaw/.openclaw \
    /home/openclaw/readonly

# 8. Shrink the rootfs. apt caches and build tooling are not needed at
#    runtime and add ~150MB to the shipped tarball.
log "[8/8] Cleaning up..."
apt-get purge -y build-essential || true
apt-get autoremove -y
apt-get clean
rm -rf /var/lib/apt/lists/* /var/cache/apt /tmp/* /var/tmp/* /root/.cache /root/.npm

log "Done. Rootfs ready for export."
