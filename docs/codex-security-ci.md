# Codex Security CI (advisory)

`.github/workflows/codex-security.yml` runs OpenAI Codex Security on
same-repository pull requests in two ways, so the two can be compared
(dogfooding):

- **`scan`**: the official CLI (`@openai/codex-security`), `scan --diff`;
- **`skills`**: the curated `codex-security` plugin (pinned 0.1.32) run by
  `codex exec`. On a PR it uses the plugin's `security-diff-scan` skill,
  because `security-scan` refuses diffs by design. On `workflow_dispatch` it
  uses `security-scan` over the whole repository.

`skills` runs after `scan` and writes CLI-vs-skills overlap counts to the step
summary. Both jobs are advisory (`continue-on-error`). They run only on a
private self-hosted runner labelled `yogit-security`, and sign in with the
maintainer's **persistent ChatGPT device-auth logins** on that runner.

## Threat model

yogit is a **public** repository. Treat every log line and step summary as
published.

| Asset | Exposure | Control |
| --- | --- | --- |
| Two ChatGPT device-auth logins (self-renewing) | Charge the maintainer's plan; read and write their Codex account for as long as the session is valid | `auth.json` files under `/srv/yogit-security/codex-home/` (0700, runner user only), never a GitHub secret, never copied per job; revoke in ChatGPT |
| Findings (unfixed vulnerabilities) | Would be a public disclosure if printed | Scanner output redirected to a 0700 directory outside the workspace; only severity counts reach `$GITHUB_STEP_SUMMARY`; no artifacts, no PR comments, no SARIF upload |
| Runner host | Runs workflow code from PR branches | Dedicated unprivileged user, hardened systemd unit, `contents: read` token, fork PRs excluded by an `if:` on head repo |

Residual risks, by design:

- **Anyone with write access can change this workflow in a PR branch and
  read the logins.** A same-repository PR runs its own version of the
  workflow. The trust boundary is therefore *repository writers*, the same
  as for any self-hosted runner secret. Keep collaborators to the
  maintainer, or move to an API key with a spend cap.
- **Fork PRs.** The job-level `if:` skips fork PRs before any runner is
  assigned, and the workflow never uses `pull_request_target`. As defence
  in depth, also set *Settings → Actions → General → Fork pull
  request workflows* to require approval for all outside collaborators, so
  a mis-edited `if:` cannot silently expose the runner.
- **Scanner output on disk.** Findings persist under
  `$CODEX_SECURITY_ARCHIVE_DIR` (`/srv/yogit-security/findings`, mode 0700)
  on the runner. Protect and prune that directory like any vulnerability
  report.

## Login lifecycle

ChatGPT **access tokens** are Business/Enterprise only, so they are not used.
Instead the runner holds the maintainer's own ChatGPT sign-in, created once
with device auth and **renewed automatically** by Codex (it carries a refresh
token). This is a personal, long-lived credential on the runner host; treat
the host accordingly.

There are **two independent logins**, one per tool:

| Path | Used by | Why separate |
| --- | --- | --- |
| `/srv/yogit-security/codex-home/cli` | `scan` (`CODEX_SECURITY_STATE_DIR`) | codex-security keeps its own Codex home inside its state dir (`cli/codex-home/auth.json`) and ignores `CODEX_HOME` |
| `/srv/yogit-security/codex-home/skills` | `skills` (`CODEX_HOME`) | the curated plugin installs into this home; sharing `cli/codex-home` would put two `codex-security` plugin versions in one home |

Each login refreshes its own token, so no `auth.json` is ever copied, which
matters because a refresh rotates the refresh token, and a stale copy would
silently stop working. The workflow-level `concurrency: yogit-security-auth`
(`cancel-in-progress: false`) and `needs: scan` make sure no two processes
refresh at once and a refresh is never cancelled midway.

Both jobs start with a `login status` preflight, so a missing or expired login
fails fast with a clear error rather than mid-scan.

**Create or renew** (as root, interactive, approves two device codes):

```sh
sudo PROVISION_LOGIN=1 bash scripts/runner/setup-yogit-security-runner.sh
```

**Revoke:** in ChatGPT, *Settings → Security* (signed-in devices and
sessions), sign out the two runner sessions. Then
`systemctl stop yogit-security-runner` and delete
`/srv/yogit-security/codex-home/{cli,skills}`. To also remove the runner, use
*Settings → Actions → Runners*.

## Host requirements

- **Sandbox:** Codex runs every scan inside bubblewrap, which needs
  unprivileged user namespaces. The unit allows exactly
  `RestrictNamespaces=user mnt net pid ipc uts` and adds `AF_NETLINK`, which
  bwrap needs to configure loopback. With `RestrictNamespaces=yes` every scan
  fails with *"No permissions to create a new namespace"*.
- **AppArmor:** on hosts with `kernel.apparmor_restrict_unprivileged_userns=1`
  (Ubuntu 24.04+), install the distro `bubblewrap` package, because only
  `/usr/bin/bwrap` carries the allowing profile.
- `git`, `curl`, Node and npm (for the one-time login install), and Python 3
  (the scanner's plugin runtime). `actions/setup-node` installs Node for jobs.

## Where findings live

- **Runner:** `/srv/yogit-security/findings/<run-id>-<attempt>/cli/` and
  `.../skills/` (canonical `scan/findings.json` for each, plus logs and the
  CLI's `findings.sarif`).
- **Codex account:** the scan is attributed to the maintainer's ChatGPT
  account. Nothing is published to GitHub code scanning.
- **GitHub:** the step summary holds counts only. These come from the
  rule-level `security-severity` score, so they are approximate; the gate is
  the scanner's own `--fail-on-severity high` exit code.

Triage on the runner:

```sh
codex-security findings list
codex-security export <dir>/scan --export-format json
```

## Kill switch

Use any one of:

- *Actions → Codex Security → Disable workflow* (instant, reversible);
- `systemctl stop yogit-security-runner` (jobs queue, nothing runs);
- revoke the logins in ChatGPT (the next job fails its login preflight).

## Cost

Every scan bills the maintainer's ChatGPT plan usage. The defaults are
model `gpt-5.6-sol` and effort `xhigh`, in Standard (not Deep) mode, with plus
one plugin-skills run per push to a same-repository PR. Runs are serialized
and never cancelled mid-flight (to protect token refresh), so a quick series
of pushes queues runs. If usage becomes a concern, consider:

- adding `--max-cost`, which applies to API-key billing estimates;
- restricting the workflow to `workflow_dispatch`;
- adding a `paths:` filter.

## Runner setup

Read `scripts/runner/setup-yogit-security-runner.sh`, then run it as root on a
private host. It is safe to re-run: once `runner/.runner` exists, the download
and registration are skipped unless `FORCE_REREGISTER=1`.

- First registration: `RUNNER_VERSION`, `RUNNER_SHA256`, `EPHEMERAL=0` and
  `REG_TOKEN_FILE=<0600 file>`. The registration token is read from the file,
  which is then deleted.
- Logins: `PROVISION_LOGIN=1`, as above. This also enables and starts the
  unit.
