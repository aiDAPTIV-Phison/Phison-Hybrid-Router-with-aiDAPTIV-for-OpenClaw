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
#    /bin/bash + no sudo group + no password => normal unprivileged user.
#
#    NOTE: the shell intentionally is /bin/bash, NOT /usr/sbin/nologin.
#
#    The earlier (systemd-driven) iteration of this design used nologin
#    as a defense-in-depth ("even if the gateway is compromised, the
#    attacker still cannot interactive-login as openclaw"). That stopped
#    working when we switched to the foreground launch model: wsl.exe
#    -u openclaw enters via PAM, PAM spawns the user's login shell, and
#    nologin promptly prints "This account is currently not available."
#    and exits 1, so the launcher's run-gateway.sh never gets a chance
#    to run.
#
#    Restoring nologin would only buy us back a defense-in-depth that
#    doesn't apply in this distro anyway: there is no sshd, no getty,
#    no external login surface, and the node gateway itself can already
#    spawn /bin/bash via child_process.spawn -- the user's *login*
#    shell setting does not gate that. Real isolation is provided by:
#      * no sudo / no password / not in any privileged group
#      * wsl.conf controls [automount] / [interop]; the windowsbridge
#        installer task decides whether the gateway sees /mnt/c and
#        cmd.exe (post-install.ps1 reports the active mode and head -1
#        /etc/wsl.conf shows it on a running distro). The other
#        defenses on this list still hold in either mode.
#      * /opt/openclaw and /opt/node are root-owned read-only (locked
#        in step 6 below)
#      * gateway binds 127.0.0.1 only
#    All of which are unaffected by the shell choice.
#
#    Ubuntu 24.04 cloud rootfs (what `ubuntu-base.tar.gz` ships) comes
#    with a pre-baked `ubuntu` user occupying UID 1000. We do not need
#    that account, and leaving it would force openclaw to a higher UID.
#    Removing it keeps openclaw at the conventional first-non-system
#    UID and trims one extra account from the rootfs.
log "[4/8] Creating openclaw user..."
if id -u ubuntu >/dev/null 2>&1; then
    log "[4/8] Removing default 'ubuntu' user to free UID 1000..."
    # `pkill -u ubuntu` would be unsafe here; userdel -f handles a stale
    # session if any. We tolerate non-zero exit (e.g. user already gone
    # in a re-run scenario) so the script stays idempotent.
    userdel --remove --force ubuntu 2>/dev/null || true
fi
if ! id -u openclaw >/dev/null 2>&1; then
    useradd --create-home --uid 1000 --shell /bin/bash openclaw
fi
# Lock the password explicitly. useradd without -p leaves the password
# field empty in /etc/shadow which on most distros means "any password
# accepted" or "locked" depending on PAM config; `passwd -l` makes it
# unambiguously locked across all configurations.
passwd -l openclaw >/dev/null 2>&1 || true

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

# 6. Install WSL boot config + foreground launcher wrapper.
#
# We deliberately do NOT enable openclaw-gateway.service. The customer
# launch model is now "click desktop icon -> Windows Terminal opens ->
# wsl.exe runs run-gateway.sh in the foreground -> Ctrl-C stops it,
# closing the window". This matches the native dev experience (`pnpm
# dev` / `node openclaw.mjs gateway run`) and lets the user see logs,
# stop the process, and restart it without learning systemctl.
#
# We still SHIP the unit file (disabled) so power users who want
# always-on daemon behaviour can `sudo systemctl enable --now
# openclaw-gateway.service` after first launch. See the design doc
# (Q5/Q7 re-evaluation in 2026-04-23-wsl-sandbox-design.md).
log "[6/8] Installing wsl.conf, run-gateway.sh, and systemd unit (disabled)..."
install -m 0644 /tmp/rootfs-config/wsl.conf /etc/wsl.conf
install -m 0644 /tmp/rootfs-config/openclaw-gateway.service \
    /etc/systemd/system/openclaw-gateway.service
# Explicitly disable the unit just in case the rootfs cache somehow
# shipped it pre-enabled. `disable` on an already-disabled unit is a
# no-op, so this is idempotent.
systemctl disable openclaw-gateway.service 2>/dev/null || true

# Foreground launcher wrapper. The Windows-side openclaw-launcher.cmd
# spawns this via `wsl.exe -d aidaptivclaw -u openclaw -- /opt/openclaw/
# run-gateway.sh` inside a Windows Terminal tab, so the user sees stdout
# / stderr in real time and can Ctrl-C to stop the gateway exactly as
# they would when running `node openclaw.mjs gateway run` natively.
#
# We `exec` node so PID 1 of the wsl session IS the node process: that
# means SIGINT from Windows Terminal's Ctrl-C reaches node directly
# without any bash wrapper swallowing it.
cat > /opt/openclaw/run-gateway.sh <<'GATEWAY_EOF'
#!/usr/bin/env bash
# Foreground gateway launcher for the WSL sandbox build.
# Invoked from Windows: wsl.exe -d aidaptivclaw -u openclaw -- /opt/openclaw/run-gateway.sh
set -e
echo "[aiDAPTIVClaw] Starting OpenClaw gateway on http://localhost:18789/"
echo "[aiDAPTIVClaw] Press Ctrl-C in this window to stop."
# Echo the active sandbox mode so users see at every launch whether the
# Windows bridge is open. The first line of /etc/wsl.conf was prepended
# by post-install.ps1 with `# MODE: STRICT SANDBOX (...)` or
# `# MODE: PERMISSIVE (...)`. We grep that out and print it as a
# one-line banner; if the marker is missing (e.g. distro provisioned
# by an older installer), we just stay silent rather than guess.
mode_line=$(head -1 /etc/wsl.conf 2>/dev/null || true)
case "${mode_line}" in
    "# MODE: "*) echo "[aiDAPTIVClaw] ${mode_line#'# '}" ;;
esac
echo ""
cd "${HOME}"
# `--force` makes the gateway take over port 18789 if a stale listener
# still holds it (e.g. previous wsl session was killed without graceful
# shutdown). `--bind loopback` binds 127.0.0.1 + ::1 only, never the
# distro's external interface.
exec /opt/node/bin/node /opt/openclaw/openclaw.mjs gateway run \
    --bind loopback --port 18789 --force
GATEWAY_EOF
chmod 0755 /opt/openclaw/run-gateway.sh

# Lock down the install dir as a substitute for the (now-disabled)
# systemd unit's ProtectSystem=strict + ProtectHome=read-only +
# ReadWritePaths= filesystem isolation.
#
# Concretely we want: openclaw user can read & execute everything
# under /opt/openclaw but cannot modify it. Step 5 set the tree to
# openclaw:openclaw to make the build work, which means openclaw
# could `chmod u+w` and write again -- ownership has to change to
# root:root before chmod, otherwise the chmod is purely advisory.
#
# `chmod -R a-w,a+rX`:
#   * a-w   -- remove write bit from owner / group / other
#   * a+rX  -- add read for everyone; capital X adds execute only on
#              directories and files that already had ANY execute bit,
#              so we don't accidentally turn .json / .md / .js into
#              executables.
#
# Effect: /opt/openclaw becomes a read-only, executable code tree.
# An LLM-driven gateway that turns hostile cannot backdoor its own
# binaries to run on next launch. It can still write /home/openclaw/
# workspace and /home/openclaw/.openclaw, where it legitimately
# stores user files and runtime state.
#
# /opt/node is already root-owned (step 2 created it as root and
# extracted the official tarball with root ownership), so the
# openclaw user has never been able to write to it. We re-chmod it
# anyway as defense-in-depth in case a future change accidentally
# chowns it.
log "[6/8] Locking /opt/openclaw and /opt/node read-only..."
chown -R root:root /opt/openclaw /opt/node
chmod -R a-w,a+rX /opt/openclaw /opt/node

# Mask Ubuntu Pro's WSL-side bridge. It is preinstalled on the Ubuntu
# 24.04 cloud rootfs and tries to talk to a Windows-side companion via
# cmd.exe. Two cases:
#   - STRICT SANDBOX mode (windowsbridge unchecked): wsl.conf disables
#     automount, so the bridge cannot find cmd.exe and fails on every
#     start, spamming the journal at ~2-second intervals (restart
#     counter climbs into the hundreds within minutes) which buries
#     our own logs.
#   - PERMISSIVE mode (windowsbridge checked): the bridge could find
#     cmd.exe, but it expects a paid Ubuntu Pro subscription on the
#     Windows side; without one it still fails (just for a different
#     reason) and still spams the journal.
# Either way the bridge is irrelevant to OpenClaw, so masking it is a
# clean no-op for functionality and a big win for log hygiene
# regardless of which sandbox mode is active.
systemctl mask wsl-pro.service || true

# 7. Pre-create writable allowlist directories. Even though the
#    foreground launcher does not have systemd's ReadWritePaths=
#    enforcement, run-gateway.sh expects these to exist (the gateway
#    writes session/log/canvas state under ~/.openclaw and treats
#    workspace/ as the project root).
log "[7/8] Creating runtime directories..."
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
