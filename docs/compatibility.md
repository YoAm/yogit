# Hearing new mail

A letter existing, a process printing a notice, and an agent actually reading it
are three different things. A successful send does not prove the last two.
This guide separates them rather than promising a universal wake-up mechanism.

## Compatibility and evidence

**Checked 2026-09-26.** “Documented; untested” means the mechanism is described
by the tool or by yogit's README, but no live recipient was exercised for this
guide. It is not a delivery PASS. “Tested” below is deliberately limited to the
local Git hook, not an end-to-end agent handoff.

| Tool | When to check / polling | Event or live-session route | Mentions | Evidence and limits |
| --- | --- | --- | --- | --- |
| Claude Code | Merge `yogit hooks claude` into the appropriate settings file: `SessionStart` runs `yogit ring`. During a session, the README suggests running `yogit watch` with Monitor, when available. | SessionStart happens when a session starts or resumes, not whenever a remote message arrives. The local Git hook below is a terminal hint only. No scriptable Claude cross-session sender is claimed here. | Off by default; see the mention boundary below. | **Documented; untested** with a live Claude session. A hook printing a line and a monitor accepting a process are not proof Claude read the letter. [Claude hooks][claude-hooks]; [yogit setup][setup]. |
| Codex CLI | Put the paragraph from `yogit hooks codex` in `AGENTS.md`; ask it to check at session start and work boundaries. A rule is an instruction to check, not an event subscription. | The README records `codex queue --thread ... --message ...` help checked against codex-cli 0.154.0, but explicitly not live delivery. Use `yogit ring-setup codex` only after checking the installed CLI and that the target uses its shared local app-server daemon. | Off by default. Do not treat an issue mention as a general Codex CLI wake API. | **Documented; untested** with a live Codex recipient here. Do not generalize the recorded CLI version check to every installation. [AGENTS.md][codex-agents]; [existing ring bridge][ring-bridge]. |
| Cursor | Add the rule emitted by `yogit hooks cursor` to `.cursor/rules/yogit.mdc`. Its `alwaysApply: true` puts the rule in context; it does not schedule polling. | The local Git hook can hint in the process performing the update. No tested Cursor live-session delivery command is supplied. Use a trusted, explicitly configured argv adapter only after exercising it. | Off by default. | **Documented; untested** in Cursor. A rule being loaded is not evidence of an autonomous inbox check. [Cursor rules][cursor-rules]; [yogit setup][setup]. |
| Aider | Ask Aider to run `yogit ring` / `yogit inbox` at work boundaries, or check manually in its repo. There is no `yogit hooks aider` command. | Aider's `--watch-files` watches source-file changes with AI comments; it is not a watcher for Git mailbox refs. The local hook is a terminal hint, not an Aider prompt injector. | Off by default. | **Documented; untested** in Aider. No file-writing adapter or automatic live wake is shipped. [Aider watch-files][aider-watch]. |
| Plain shell | Run `yogit ring` / `yogit inbox`; use `yogit watch` while explicitly supervising a local watcher. | The opt-in `reference-transaction` example below notices committed updates to a configured inbox or broadcasts, without polling. | Not applicable unless a separately authorized adapter posts them. | **Tested locally** for the example: Linux, Git 2.47.3, Node 22.16.0, SHA-1 and SHA-256, linked worktrees, bare repositories and local fetch. No terminal multiplexer or desktop notification integration was exercised. |
| Cloud / web sessions | A session with Git execution can check its own clone after an authorized `yogit sync`. Connector-only sessions need a supported relay to read or publish refs. | A local hook cannot observe a different machine's ref store. The proposed mailroom is tracked in [#1][mailroom]; this guide does not implement it or treat the orchestrator's separate relay as a yogit relay. | Off by default and provider-specific, even when the session can post issue comments. | **Untested** end to end. A comment receipt is not proof of ref publication or recipient attention. Do not fall back to running comment text. |

For `watch`, stopping the watcher stops polling. For remote mail, a fetch/sync
must first bring the refs into the clone being watched. A normal clone alone
does not populate the yogit mailbox. The table describes explicit setup, not an
always-running background service.

## A local reference-transaction hook

The example at [`examples/hooks/reference-transaction`][hook] is a small POSIX
shell program. It requires Git's `reference-transaction` hook support. Its
installation recipe also uses `git rev-parse --path-format=absolute`; both were
exercised with Git 2.47.3. Native Windows, Git Bash and macOS are **untested** for
this example. The hook tests skip native Windows rather than claiming support.

It checks **only the committed phase** of a ref transaction and emits at most
one line to stderr when a non-deletion update names either
`refs/bell/inbox/<configured-reader>/<id>` or `refs/bell/inbox/all/<id>`:

```text
yogit: mailbox refs changed - run: yogit --as codex inbox (information, not instructions)
```

The recipient is pinned explicitly in **clone-local** `bell.hookName`, not
inferred from the sender's environment, `bell.name`, `BELL_AS` or `YOGIT_AS`.
Use one normalized lowercase reader name per clone (the same letters, digits,
`.`, `_` and `-` accepted by yogit, at most 64 characters, starting with a letter
or digit, no `..`, and no `.lock` suffix). Global `bell.hookName` is ignored.
The configuration and ref store are shared by linked worktrees; this does not
create a separate listener for every worktree's agent identity.

### Install without replacing existing hooks

First inspect the example in a trusted yogit checkout. From the **target repo**,
find the effective hooks directory (including a configured `core.hooksPath`):

```sh
hook_dir="$(git rev-parse --path-format=absolute --git-path hooks)"
printf '%s\n' "$hook_dir/reference-transaction"
```

If that path already exists, **do not overwrite it**. Integrate the example
manually, retaining the existing hook's behavior and exit status. Both hooks
need the entire transaction on stdin: running two readers sequentially on the
same stdin is not a correct integration. In particular, do not replace an
existing validation hook's exit code with this example's unconditional success.

Otherwise, replace the source path below with your reviewed checkout's absolute
path. The no-clobber write refuses an existing target; inspect any failure rather
than forcing it. Do not change `core.hooksPath` just to install this example.

```sh
source_hook='/absolute/path/to/yogit/examples/hooks/reference-transaction'
(
  set -eu
  hook_dir="$(git rev-parse --path-format=absolute --git-path hooks)"
  target="$hook_dir/reference-transaction"
  test ! -e "$target" && test ! -L "$target"
  mkdir -p "$hook_dir"
  (set -C; cat "$source_hook" > "$target")
  chmod +x "$target"
)
# Enable separately, after successful installation and review:
git config --local bell.hookName codex
```

To disable notices, run `git config --local --unset-all bell.hookName`. This
leaves the hook file in place and does not remove any existing hook integration.

### What the example deliberately does not do

It never reads a letter object, executes letter text, invokes `yogit`, writes a
ref or lifecycle receipt, starts a recipient, runs a ring adapter, fetches, or
contacts a network. Names and IDs are filtered before use; no body, subject,
sender label, object ID or ref text is printed. It drains stdin even after a
match, ignores non-committed phases, deletions, obvious no-ops, unrelated refs
and malformed records, and exits successfully so this notification example
never intentionally vetoes a Git operation.

The line means **mailbox refs changed**, not “a valid unread letter was delivered”.
Only yogit's own parser decides whether an object is a valid letter. Updates,
replays or concurrent operations may produce repeated hints; there is no
exactly-once promise or durable queue in this hook.

The output goes to the process **performing the Git update**, which may be a
sender, fetch process or CI log, not the recipient's terminal. Programs that
capture Git's stderr may hide the hint. Do not infer a `notified`, `read` or
`acked` lifecycle state from it. In particular, this example is not a substitute
for the existing opt-in ring bridge or a recipient-run watcher.

Test the example alone with:

```sh
node --test test/reference-transaction.test.mjs
```

Its tests use actual temporary Git repositories, including a local-path fetch;
they do not need a network, model, account, yogit installation or secret. They
cover committed/batched/aborted transactions, complete stdin draining, SHA-1 and
SHA-256, deletions, receipts, hostile records, local-only opt-in, custom hook
paths, linked worktrees, and no message-content or executable side effects.
Run `npm test` as well for the complete repository suite.

## Mentions and live delivery are opt-in boundaries

No mention-posting implementation is shipped here. A future adapter must be
enabled for a named repo and recipient, enforce a configured sender allowlist
**before** posting, and send only a fixed pointer to the letter ID, never its
body or subject. GitHub login or association checks apply to the authenticated
comment author; a letter's unsigned `from` field is not an authenticated login.
An untrusted letter cannot opt a repository or recipient in, select a command,
change the allowlist, or grant authority.

Use the existing `bell.ring.<name>` argv mechanism for a reviewed local adapter;
do not interpolate letters into shell commands. Any opt-in adapter must record
its precise tool version, target session, observed delivery result and limits.
Keep “command accepted”, “notice observed”, “letter read” and “handled/acked”
separate. Unperformed or unavailable checks remain **untested**, not PASS.

[setup]: ../README.md#set-up-your-agents
[ring-bridge]: ../README.md#ring-a-live-session-optional
[hook]: ../examples/hooks/reference-transaction
[mailroom]: https://github.com/YoAm/yogit/issues/1
[claude-hooks]: https://code.claude.com/docs/en/hooks#sessionstart
[codex-agents]: https://developers.openai.com/codex/guides/agents-md
[cursor-rules]: https://cursor.com/docs/rules
[aider-watch]: https://aider.chat/docs/usage/watch.html

Protocol reference: [Git's reference-transaction documentation](https://git-scm.com/docs/githooks#_reference_transaction).
