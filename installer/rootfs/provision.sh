#!/usr/bin/env bash
# Provision the `aidaptivclaw` WSL distro on the customer machine.
# Runs as root inside the customer's freshly-imported Ubuntu 24.04 base
# rootfs, orchestrated by `installer/post-install.ps1` (Phase 2).
#
# Inputs (pre-staged into the customer's distro by post-install.ps1):
#   /tmp/openclaw-source.tar.gz  OpenClaw source tarball (from `git archive HEAD`)
#   /tmp/rootfs-config/          wsl.conf + openclaw-gateway.service
#
# Environment overrides:
#   NODE_VERSION (default: 22.17.0)
#   PNPM_VERSION (default: 9.12.0)
#
# Network: this script REQUIRES internet access (apt, nodejs.org,
# github.com for pnpm, npm registry). If install fails partway through,
# post-install.ps1 will `wsl --unregister aidaptivclaw` and the user can
# retry once network is restored.
set -euo pipefail

# Node.js LTS line. Pin >= 22.16.0 because some transitive deps now
# declare engines.node >= 22.16.0 and pnpm refuses to run lifecycle
# scripts (e.g. `pnpm build`) when engine-strict is enforced.
NODE_VERSION="${NODE_VERSION:-22.17.0}"
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
#
#    Ubuntu 24.04 cloud rootfs (what `ubuntu-base.tar.gz` ships) comes
#    with a pre-baked `ubuntu` user occupying UID 1000. We do not need
#    that account, and leaving it would force openclaw to a higher UID.
#    Removing it keeps openclaw at the conventional first-non-system UID
#    and reduces the attack surface (one fewer shell-capable account).
log "[4/8] Creating openclaw user..."
if id -u ubuntu >/dev/null 2>&1; then
    log "[4/8] Removing default 'ubuntu' user to free UID 1000..."
    # `pkill -u ubuntu` would be unsafe here; userdel -f handles a stale
    # session if any. We tolerate non-zero exit (e.g. user already gone
    # in a re-run scenario) so the script stays idempotent.
    userdel --remove --force ubuntu 2>/dev/null || true
fi
if ! id -u openclaw >/dev/null 2>&1; then
    useradd --create-home --uid 1000 --shell /usr/sbin/nologin openclaw
fi

# 5. Build OpenClaw. Source arrives as a tarball produced by `git archive`
#    on the build machine and shipped inside the .exe; only commit-tracked
#    files are present (no node_modules / .git noise).
#    We build as root for simplicity and chown to openclaw at the end.
log "[5/8] Building OpenClaw..."
SRC_TARBALL="/tmp/openclaw-source.tar.gz"
SRC_DIR="/tmp/openclaw-src"
test -f "${SRC_TARBALL}" || {
    echo "ERROR: ${SRC_TARBALL} missing — orchestrator must stage source first" >&2
    exit 1
}
mkdir -p "${SRC_DIR}"
tar -xzf "${SRC_TARBALL}" -C "${SRC_DIR}"
cd "${SRC_DIR}"
pnpm install --ignore-scripts
# Native modules used by OpenClaw — explicit rebuild keeps the install
# step lean (--ignore-scripts above) while still producing working binaries.
pnpm rebuild esbuild sharp koffi protobufjs
# Use `pnpm build` (NOT `build:docker`). The `build:docker` variant skips
# `canvas:a2ui:bundle` because the official Docker build excludes
# `vendor/` and `apps/` via .dockerignore — there is no a2ui source to
# compile inside that image. Our installer ships the source via
# `git archive HEAD` which DOES include vendor/ and apps/, so the
# bundle step can and must run; otherwise `src/canvas-host/a2ui/
# a2ui.bundle.js` will be missing at runtime and any A2UI canvas
# rendering in the UI will fail to load.
pnpm build
pnpm ui:build

mkdir -p /opt/openclaw
cp -a "${SRC_DIR}"/. /opt/openclaw/
chown -R openclaw:openclaw /opt/openclaw
rm -rf "${SRC_DIR}" "${SRC_TARBALL}"

# 6. Install WSL boot config + systemd unit.
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

# 8. Shrink the distro. apt caches and build tooling are not needed at
#    runtime and add ~150MB. We keep the customer's distro small even
#    though it is no longer "shipped" (the build happens on their box).
log "[8/8] Cleaning up..."
apt-get purge -y build-essential || true
apt-get autoremove -y
apt-get clean
rm -rf /var/lib/apt/lists/* /var/cache/apt /tmp/* /var/tmp/* /root/.cache /root/.npm

log "Done. Distro provisioned."
