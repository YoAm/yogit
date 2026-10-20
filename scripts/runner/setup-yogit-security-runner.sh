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
#   5. optionally (PROVISION_ACCESS_TOKEN=1) reads the ChatGPT access token
#      from a hidden prompt into the runner's 0600 token file and starts the unit.
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

REPO_URL="${REPO_URL:-https://github.com/YoAm/yogit}"
RUNNER_USER="${RUNNER_USER:-yogit-security}"
RUNNER_HOME="${RUNNER_HOME:-/srv/yogit-security}"
RUNNER_NAME="${RUNNER_NAME:-$(hostname -s)-yogit-security}"
RUNNER_LABELS="yogit-security"
EPHEMERAL="${EPHEMERAL:-1}"
# Set both to the release you reviewed: https://github.com/actions/runner/releases
RUNNER_VERSION="${RUNNER_VERSION:?set RUNNER_VERSION, e.g. 2.329.0}"
RUNNER_SHA256="${RUNNER_SHA256:?set RUNNER_SHA256 from the release notes}"

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
REG_TOKEN_FILE="${REG_TOKEN_FILE:-}"
PROVISION_ACCESS_TOKEN="${PROVISION_ACCESS_TOKEN:-0}"
if [ -z "$REG_TOKEN_FILE" ] || [ "$PROVISION_ACCESS_TOKEN" = "1" ]; then
  [ -t 0 ] || { echo "interactive terminal required (token prompt)" >&2; exit 1; }
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
  "$RUNNER_HOME" "$RUNNER_HOME/runner" "$RUNNER_HOME/secrets" "$RUNNER_HOME/findings"

tarball="actions-runner-linux-${arch}-${RUNNER_VERSION}.tar.gz"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
curl -fsSL -o "$tmp/$tarball" \
  "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${tarball}"
echo "${RUNNER_SHA256}  $tmp/$tarball" | sha256sum -c -
runuser -u "$RUNNER_USER" -- tar -xzf "$tmp/$tarball" -C "$RUNNER_HOME/runner"

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
Environment=CODEX_SECURITY_TOKEN_FILE=${RUNNER_HOME}/secrets/codex-access-token
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
RestrictNamespaces=yes
LockPersonality=yes
SystemCallArchitectures=native
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
CapabilityBoundingSet=
MemoryMax=8G
TasksMax=2048

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload

if [ "$PROVISION_ACCESS_TOKEN" = "1" ]; then
  token_path="$RUNNER_HOME/secrets/codex-access-token"
  printf 'ChatGPT Codex access token (input hidden): '
  IFS= read -rs access_token
  echo
  [ -n "$access_token" ] || { echo "empty access token; unit left stopped" >&2; exit 1; }
  install -m 0600 -o "$RUNNER_USER" -g "$RUNNER_USER" /dev/null "$token_path"
  printf '%s\n' "$access_token" > "$token_path"
  unset access_token
  systemctl enable --now yogit-security-runner.service
  systemctl --no-pager --lines=0 status yogit-security-runner.service || true
else
  echo "Unit installed but NOT started. Provision the token file first (runbook), then:"
  echo "  systemctl enable --now yogit-security-runner.service"
fi
