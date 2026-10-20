# Codex Security CI (advisory)

`.github/workflows/codex-security.yml` runs an OpenAI Codex Security **diff
scan** on same-repository pull requests. It is advisory (`continue-on-error`),
runs only on a private self-hosted runner labelled `yogit-security`, and signs
in with the maintainer's ChatGPT **access token**.

Nothing is registered and no token is stored by the pull request that added
this file. Until a runner exists, jobs simply queue.

## Threat model

yogit is a **public** repository. Treat every log line and step summary as
published.

| Asset | Exposure | Control |
| --- | --- | --- |
| ChatGPT access token | Charges the maintainer's subscription; reads/writes their Codex account | Runner-local file (0600, runner user only), never a GitHub secret; per-job credential home deleted in an `always()` step |
| Findings (unfixed vulnerabilities) | Would be a public disclosure if printed | Scanner output redirected to a 0700 directory outside the workspace; only severity counts reach `$GITHUB_STEP_SUMMARY`; no artifacts, no PR comments, no SARIF upload |
| Runner host | Runs workflow code from PR branches | Dedicated unprivileged user, hardened systemd unit, `contents: read` token, fork PRs excluded by an `if:` on head repo |

Residual risks, by design:

- **Anyone with write access can change this workflow in a PR branch and
  read the token.** A same-repository PR runs its own version of the
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

OpenAI's guidance (learn.chatgpt.com/docs/auth) is that access tokens are
"intended for trusted scripts, schedulers, and private CI runners", that API
keys remain the recommended default for automation, and not to expose Codex
execution in untrusted or public environments. This setup follows the first
by keeping the credential and findings on a private host; the public
repository is the reason for the counts-only output.

## Token lifecycle

1. **Create** a Codex access token in ChatGPT (workspace admins may need to
   grant the permission).
2. **Provision** it on the runner, as root, without it touching shell history
   or argv:

   ```sh
   install -m 0600 -o yogit-security -g yogit-security /dev/null \
     /srv/yogit-security/secrets/codex-access-token
   # paste the token, then Ctrl-D
   cat > /srv/yogit-security/secrets/codex-access-token
   ```

3. **Each job** copies the token into a fresh per-job Codex home via
   `codex-security login --with-access-token` (stdin), scans, then deletes
   that home.

**Refresh: the token does not refresh itself.** A ChatGPT browser sign-in
carries a refresh token and Codex renews it during use. An access token
supplied on stdin is only a bearer credential. OpenAI's docs do not state
its lifetime. When it expires, the login or scan step fails, the job turns
red (advisory, non-blocking), and the summary says the scan did not
complete. The fix is to create a new token and repeat step 2.

**Why not `ephemeral` storage.** Codex's
`cli_auth_credentials_store = "ephemeral"` keeps credentials in memory for
the current process only. `codex-security login` and `codex-security scan`
are separate processes, so the scan would start signed out. The workflow
therefore uses the `file` store (an `auth.json` in plaintext) inside a
per-job directory: mode 0700, outside the checkout, owned by the runner
user, deleted when the job ends. That plaintext `auth.json` lives for the
duration of one job.

The alternative is persisting a normal ChatGPT sign-in (with its refresh
token) in the runner user's `~/.codex/auth.json`. It never needs
reprovisioning, but it leaves a long-lived, refreshable credential on disk
permanently. It is not the default here.

## Rotation and revocation

- **Rotate:** create a new token, overwrite the file (step 2), then revoke
  the old token in ChatGPT. No workflow change is needed.
- **Revoke on suspicion:** revoke the token in ChatGPT first. Then
  `systemctl stop yogit-security-runner`, delete the token file, and remove
  the runner under *Settings → Actions → Runners*.

## Where findings live

- **Runner:** `/srv/yogit-security/findings/<run-id>-<attempt>/`
  (`findings.json`, `scan.stderr`, `scan/` results, `findings.sarif`).
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
- delete the token file (the next job fails at sign-in).

## Cost

Every scan bills the maintainer's ChatGPT plan usage. The defaults are
model `gpt-5.6-sol` and effort `xhigh`, in Standard (not Deep) mode, with one
scan per push to a same-repository PR. `cancel-in-progress` drops superseded
pushes. If usage becomes a concern, consider:

- adding `--max-cost`, which applies to API-key billing estimates;
- restricting the workflow to `workflow_dispatch`;
- adding a `paths:` filter.

## Runner setup

Read `scripts/runner/setup-yogit-security-runner.sh` and run it as root on a
private host. It does **not** start the service and does **not** provision
the token. The host needs `git`, `curl`, and Python 3 for the scanner's
plugin runtime. `actions/setup-node` installs Node.
