#!/usr/bin/env bash
# Provision a dedicated, private GitHub Actions runner for the advisory
# Codex Security workflow (.github/workflows/codex-security.yml).
#
# NOT run by CI. A maintainer runs this by hand, as root, on a private host
# they control, after reading docs/codex-security-ci.md. It:
#   1. creates an unprivileged system user with no login shell;
#   2. downloads and verifies the actions/runner release;
#   3. registers the runner with the label `yogit-security`, reading the
#      registration token from REG_TOKEN_FILE (deleted after use) or, if unset,
#      interactively (never from argv or the environment);
#   4. installs a hardened systemd unit;
#   5. optionally (PROVISION_LOGIN=1) creates the two persistent ChatGPT
#      device-auth logins the workflow uses, then starts the unit.
#
# Safe to re-run: once the runner is registered (runner/.runner exists) the
# download and registration are skipped unless FORCE_REREGISTER=1.
#
# Logins (PROVISION_LOGIN=1). ChatGPT access tokens are Business/Enterprise
# only, so the runner holds a personal, self-renewing device-auth login
# instead. Two independent logins are created under CODEX_SECURITY_HOME, one
# per tool, because codex-security keeps its Codex home inside its own state
# dir (<state>/codex-home) and the plugin-skills job needs a plain CODEX_HOME:
#   $CODEX_SECURITY_HOME/cli     CODEX_SECURITY_STATE_DIR for codex-security
#   $CODEX_SECURITY_HOME/skills  CODEX_HOME for the codex CLI
# Each refreshes its own token; no auth.json is ever copied or shared.
#
# Ephemeral vs persistent registration:
#   EPHEMERAL=1 (default) registers with --ephemeral: the runner takes one job
#   and deregisters, so it needs a fresh registration token per job. That is
#   the safest shape but needs a re-registration loop (out of scope here).
#   EPHEMERAL=0 registers a persistent runner that this unit keeps running.
#   The workflow deletes its per-job credential and findings directory either
#   way, so persistent is acceptable for a single-repo, same-repo-PR-only
#   runner; see the runbook's threat model before choosing.
set -euo pipefail
# runuser children inherit the caller's cwd; a cwd the runner user cannot
# resolve (e.g. the maintainer's 0700 home) makes npm die with uv_cwd ENOENT.
cd /

REPO_URL="${REPO_URL:-https://github.com/YoAm/yogit}"
RUNNER_USER="${RUNNER_USER:-yogit-security}"
RUNNER_HOME="${RUNNER_HOME:-/srv/yogit-security}"
RUNNER_NAME="${RUNNER_NAME:-$(hostname -s)-yogit-security}"
RUNNER_LABELS="yogit-security"
EPHEMERAL="${EPHEMERAL:-1}"
# Set both to the release you reviewed: https://github.com/actions/runner/releases
# Needed only when (re-)registering.
RUNNER_VERSION="${RUNNER_VERSION:-}"
RUNNER_SHA256="${RUNNER_SHA256:-}"

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
REG_TOKEN_FILE="${REG_TOKEN_FILE:-}"
PROVISION_LOGIN="${PROVISION_LOGIN:-0}"
FORCE_REREGISTER="${FORCE_REREGISTER:-0}"
CODEX_SECURITY_HOME="${CODEX_SECURITY_HOME:-$RUNNER_HOME/codex-home}"
CODEX_SECURITY_VERSION="${CODEX_SECURITY_VERSION:-0.5.0}"
CODEX_VERSION="${CODEX_VERSION:-0.162.1}"
registered=0
[ -f "$RUNNER_HOME/runner/.runner" ] && [ "$FORCE_REREGISTER" != "1" ] && registered=1
if { [ "$registered" = "0" ] && [ -z "$REG_TOKEN_FILE" ]; } || [ "$PROVISION_LOGIN" = "1" ]; then
  [ -t 0 ] || { echo "interactive terminal required (token prompt or device-auth code)" >&2; exit 1; }
fi
# Codex runs every scan inside its bubblewrap sandbox, which needs
# unprivileged user namespaces. Where AppArmor restricts them (Ubuntu 24.04+),
# only the distro bwrap at /usr/bin/bwrap carries the allowing profile.
if [ "$(sysctl -n kernel.unprivileged_userns_clone 2>/dev/null || echo 1)" = "0" ]; then
  echo "kernel.unprivileged_userns_clone=0: Codex's bubblewrap sandbox cannot start" >&2; exit 1
fi
if [ "$(sysctl -n kernel.apparmor_restrict_unprivileged_userns 2>/dev/null || echo 0)" = "1" ] \
  && [ ! -x /usr/bin/bwrap ]; then
  echo "AppArmor restricts user namespaces and /usr/bin/bwrap is missing: apt install bubblewrap" >&2; exit 1
fi

case "$(uname -m)" in
  x86_64) arch=x64 ;;
  aarch64) arch=arm64 ;;
  *) echo "unsupported architecture $(uname -m)" >&2; exit 1 ;;
esac

if ! id "$RUNNER_USER" >/dev/null 2>&1; then
  useradd --system --home-dir "$RUNNER_HOME" --create-home \
    --shell /usr/sbin/nologin "$RUNNER_USER"
fi
install -d -m 0700 -o "$RUNNER_USER" -g "$RUNNER_USER" \
  "$RUNNER_HOME" "$RUNNER_HOME/runner" "$RUNNER_HOME/findings" "$RUNNER_HOME/tool" \
  "$CODEX_SECURITY_HOME" "$CODEX_SECURITY_HOME/cli" "$CODEX_SECURITY_HOME/cli/codex-home" \
  "$CODEX_SECURITY_HOME/skills"

if [ "$registered" = "1" ]; then
  echo "Runner already registered ($RUNNER_HOME/runner/.runner); skipping download and registration (FORCE_REREGISTER=1 to redo)."
else
[ -n "$RUNNER_VERSION" ] && [ -n "$RUNNER_SHA256" ] || { echo "set RUNNER_VERSION and RUNNER_SHA256 to register" >&2; exit 1; }
tarball="actions-runner-linux-${arch}-${RUNNER_VERSION}.tar.gz"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
curl -fsSL -o "$tmp/$tarball" \
  "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${tarball}"
echo "${RUNNER_SHA256}  $tmp/$tarball" | sha256sum -c -
# Extract as root (the mktemp dir is 0700 root), then hand the tree to the runner user.
tar -xzf "$tmp/$tarball" -C "$RUNNER_HOME/runner" --no-same-owner
chown -R "$RUNNER_USER:$RUNNER_USER" "$RUNNER_HOME/runner"

if [ -n "$REG_TOKEN_FILE" ]; then
  [ -f "$REG_TOKEN_FILE" ] && [ ! -L "$REG_TOKEN_FILE" ] || { echo "REG_TOKEN_FILE is not a regular file" >&2; exit 1; }
  [ "$(stat -c %a "$REG_TOKEN_FILE")" = "600" ] || { echo "REG_TOKEN_FILE must be mode 0600" >&2; exit 1; }
  IFS= read -r reg_token < "$REG_TOKEN_FILE" || true
  rm -f -- "$REG_TOKEN_FILE"
else
  printf 'Registration token for %s (input hidden): ' "$REPO_URL"
  IFS= read -rs reg_token
  echo
fi
[ -n "$reg_token" ] || { echo "empty token" >&2; exit 1; }

config_args=(--unattended --url "$REPO_URL" --name "$RUNNER_NAME"
  --labels "$RUNNER_LABELS" --no-default-labels --work _work --replace)
[ "$EPHEMERAL" = "1" ] && config_args+=(--ephemeral)
# The runner's config.sh accepts the token only as an argument; it is passed
# to the child process only and never written to disk or shell history here.
(cd "$RUNNER_HOME/runner" && runuser -u "$RUNNER_USER" -- ./config.sh "${config_args[@]}" --token "$reg_token")
unset reg_token
fi

cat > /etc/systemd/system/yogit-security-runner.service <<UNIT
[Unit]
Description=GitHub Actions runner (yogit Codex Security, advisory)
After=network-online.target
Wants=network-online.target

[Service]
User=${RUNNER_USER}
Group=${RUNNER_USER}
WorkingDirectory=${RUNNER_HOME}/runner
ExecStart=${RUNNER_HOME}/runner/run.sh
Environment=CODEX_SECURITY_HOME=${CODEX_SECURITY_HOME}
Environment=CODEX_SECURITY_ARCHIVE_DIR=${RUNNER_HOME}/findings
UMask=0077
Restart=on-failure
RestartSec=30
KillMode=control-group
TimeoutStopSec=5min
NoNewPrivileges=yes
ProtectSystem=strict
ReadWritePaths=${RUNNER_HOME}
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
RestrictSUIDSGID=yes
RestrictRealtime=yes
# Codex runs every scan (CLI and plugin skills) inside its bubblewrap
# sandbox, which needs unprivileged user, mount, net, pid, ipc and uts
# namespaces. RestrictNamespaces=yes makes bwrap fail ("No permissions to
# create a new namespace") and the scan never starts. Allow exactly those;
# cgroup and time namespaces stay restricted.
RestrictNamespaces=user mnt net pid ipc uts
LockPersonality=yes
SystemCallArchitectures=native
# AF_NETLINK: bwrap configures loopback in the sandbox's network namespace.
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK
CapabilityBoundingSet=
MemoryMax=8G
TasksMax=2048

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload

if [ "$PROVISION_LOGIN" = "1" ]; then
  as_runner() { runuser -u "$RUNNER_USER" -- env -i HOME="$RUNNER_HOME" PATH=/usr/local/bin:/usr/bin:/bin "$@"; }
  # Force the plaintext file store: the runner user has no keyring.
  for cfg in "$CODEX_SECURITY_HOME/cli/codex-home/config.toml" "$CODEX_SECURITY_HOME/skills/config.toml"; do
    [ -f "$cfg" ] || install -m 0600 -o "$RUNNER_USER" -g "$RUNNER_USER" /dev/null "$cfg"
    grep -q '^cli_auth_credentials_store' "$cfg" || printf 'cli_auth_credentials_store = "file"\n' >> "$cfg"
  done
  echo "Installing pinned tools (no install scripts) into $RUNNER_HOME/tool"
  as_runner npm install --prefix "$RUNNER_HOME/tool" --no-save --no-audit --no-fund --ignore-scripts \
    "@openai/codex-security@${CODEX_SECURITY_VERSION}" "@openai/codex@${CODEX_VERSION}" > /dev/null
  echo
  echo "== Login 1 of 2: codex-security (CLI scan job). Approve the device code in your browser."
  as_runner CODEX_SECURITY_STATE_DIR="$CODEX_SECURITY_HOME/cli" \
    "$RUNNER_HOME/tool/node_modules/.bin/codex-security" login --device-auth
  as_runner CODEX_SECURITY_STATE_DIR="$CODEX_SECURITY_HOME/cli" \
    "$RUNNER_HOME/tool/node_modules/.bin/codex-security" login status
  echo
  echo "== Login 2 of 2: codex (plugin-skills job). Approve the second device code."
  as_runner CODEX_HOME="$CODEX_SECURITY_HOME/skills" \
    "$RUNNER_HOME/tool/node_modules/.bin/codex" login --device-auth
  as_runner CODEX_HOME="$CODEX_SECURITY_HOME/skills" \
    "$RUNNER_HOME/tool/node_modules/.bin/codex" login status
  systemctl enable --now yogit-security-runner.service
  systemctl --no-pager --lines=0 status yogit-security-runner.service || true
else
  echo "Unit installed but NOT started. Provision the logins first (PROVISION_LOGIN=1), then:"
  echo "  systemctl enable --now yogit-security-runner.service"
fi
