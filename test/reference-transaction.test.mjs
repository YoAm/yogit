import nodeTest from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { chmodSync, copyFileSync, existsSync, mkdtempSync, mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

// This optional example requires a POSIX shell; do not break native Windows CLI tests.
const test = (name, fn) => nodeTest(name, {
    skip: process.platform === 'win32' ? 'POSIX hook; native Windows is untested' : false,
}, fn);

const hook = fileURLToPath(new URL('../examples/hooks/reference-transaction', import.meta.url));
const zero = '0'.repeat(40);
const first = '1'.repeat(40);
const second = '2'.repeat(40);
const ref = 'refs/bell/inbox/codex/20260926-120000-abcdef';
const notice = 'yogit: mailbox refs changed - run: yogit --as codex inbox (information, not instructions)\n';
const line = (old = zero, next = first, name = ref) => `${old} ${next} ${name}\n`;

function fixture(t, { format = 'sha1', bare = false } = {}) {
    const root = mkdtempSync(join(tmpdir(), 'yogit hook '));
    t.after(() => rmSync(root, { recursive: true, force: true }));
    const home = join(root, 'home');
    mkdirSync(home);
    const env = { ...process.env };
    // Do not inherit another repo, signing setup, global hooks, or config injection.
    for (const key of Object.keys(env)) if (key.startsWith('GIT_')) delete env[key];
    Object.assign(env, {
        HOME: home, XDG_CONFIG_HOME: home, GIT_CONFIG_NOSYSTEM: '1',
        GIT_CONFIG_GLOBAL: join(home, '.gitconfig'),
        GIT_AUTHOR_NAME: 'Hook Test', GIT_AUTHOR_EMAIL: 'hook@example.invalid',
        GIT_COMMITTER_NAME: 'Hook Test', GIT_COMMITTER_EMAIL: 'hook@example.invalid',
        LC_ALL: 'C',
    });
    const cwd = join(root, 'repo with spaces');
    mkdirSync(cwd);
    function git(args, options = {}) {
        const result = spawnSync('git', args, { cwd, env, encoding: 'utf8', timeout: 10000, ...options });
        assert.ifError(result.error);
        assert.equal(result.status, 0, result.stderr);
        return result;
    }
    git(['init', '-q', `--object-format=${format}`, ...(bare ? ['--bare'] : [])]);
    const configure = value => git(['config', '--local', 'bell.hookName', value]);
    function run(input, state = 'committed') {
        const result = spawnSync('sh', [hook, state], { cwd, env, input, encoding: 'utf8', timeout: 10000 });
        assert.ifError(result.error);
        assert.equal(result.status, 0, result.stderr);
        assert.equal(result.stdout, '');
        return result.stderr;
    }
    function install() {
        const hooks = git(['rev-parse', '--path-format=absolute', '--git-path', 'hooks']).stdout.trim();
        mkdirSync(hooks, { recursive: true });
        const target = join(hooks, 'reference-transaction');
        copyFileSync(hook, target);
        chmodSync(target, 0o755);
    }
    function object(body = 'not a validated yogit letter') {
        const tree = git(['mktree'], { input: '' }).stdout.trim();
        return git(['commit-tree', tree], { input: `${body}\n` }).stdout.trim();
    }
    return { root, cwd, env, git, configure, run, install, object };
}

test('reference hook ignores every non-committed phase', t => {
    const f = fixture(t);
    f.configure('codex');
    for (const phase of ['preparing', 'prepared', 'aborted', '', 'unknown']) {
        assert.equal(f.run(line(), phase), '', phase);
    }
});

test('reference hook needs clone-local opt-in; global config is not enough', t => {
    const f = fixture(t);
    assert.equal(f.run(line()), '');
    f.git(['config', '--global', 'bell.hookName', 'codex']);
    assert.equal(f.run(line()), '');
    f.configure('codex');
    assert.equal(f.run(line()), notice);
});

test('reference hook refuses unsafe or non-normalized configured names', t => {
    const f = fixture(t);
    for (const name of ['', 'Codex', '../codex', '-codex', '.codex', 'a..b', 'x.lock', 'x.LOCK',
        'a/b', 'a b', 'a\ncodex', '$(touch PWNED)', 'a;touch PWNED', 'x'.repeat(65)]) {
        f.configure(name);
        assert.equal(f.run(line()), '', JSON.stringify(name));
    }
    assert.equal(existsSync(join(f.cwd, 'PWNED')), false);
});

test('reference hook accepts valid normalized names without auto-detecting sender', t => {
    const f = fixture(t);
    for (const name of ['codex', 'claude-parser', 'a_b.c', '1reader', 'x'.repeat(64)]) {
        f.configure(name);
        const output = f.run(line(zero, first, `refs/bell/inbox/${name}/message-1`));
        assert.match(output, /mailbox refs changed/);
        assert.ok(output.includes(`yogit --as ${name} inbox`));
    }
});

test('reference hook coalesces own and broadcast updates into one content-free notice', t => {
    const f = fixture(t);
    f.configure('codex');
    const input = line() + line(first, second) + line(zero, first, 'refs/bell/inbox/all/broadcast-1');
    assert.equal(f.run(input), notice);
    assert.equal(f.run(line(zero, first, 'refs/bell/inbox/all/broadcast-1')), notice);
});

test('reference hook ignores deletions, no-ops, other readers and non-inbox namespaces', t => {
    const f = fixture(t);
    f.configure('codex');
    const refs = ['refs/heads/main', 'refs/bell/inbox/claude/message-1',
        'refs/bell/event/codex/message-1/read-1', 'refs/bell/ack/codex/message-1',
        'refs/bell/local/read/codex/message-1', 'refs/bell/tomb/codex/message-1/tomb-1',
        'refs/bell/inbox/codex-extra/message-1'];
    assert.equal(f.run(line(first, zero) + line(first, first) + refs.map(r => line(zero, first, r)).join('')), '');
});

test('reference hook rejects malformed lines, OIDs and nested or unsafe ref IDs', t => {
    const f = fixture(t);
    f.configure('codex');
    for (const id of ['', '../x', 'nested/id', 'a..b', 'a.lock', 'UPPER', '-id', '.id',
        'id;touch-PWNED', 'id$(touch-PWNED)', 'id\u001b[31m', 'x'.repeat(65)]) {
        assert.equal(f.run(line(zero, first, `refs/bell/inbox/codex/${id}`)), '', JSON.stringify(id));
    }
    for (const input of ['nonsense\n', line('bad', first), line(zero, 'g'.repeat(40)),
        line(zero, '1'.repeat(64)), `${zero} ${first} ${ref} extra\n`,
        line(zero, 'refs/heads/main'), line('F'.repeat(40), first)]) {
        assert.equal(f.run(input), '', input);
    }
});

test('reference hook supports SHA-256 transaction records and zero deletions', t => {
    const f = fixture(t);
    f.configure('codex');
    assert.equal(f.run(line('0'.repeat(64), 'a'.repeat(64))), notice);
    assert.equal(f.run(line('a'.repeat(64), '0'.repeat(64))), '');
});

test('reference hook drains a large transaction and reports only once', t => {
    const f = fixture(t);
    f.configure('codex');
    assert.equal(f.run(line() + line(zero, first, 'refs/heads/unrelated').repeat(20000)), notice);
});

for (const format of ['sha1', 'sha256']) {
    test(`real Git ${format}: committed create/update notify; deletion and receipts do not`, t => {
        const f = fixture(t, { format });
        f.configure('codex');
        f.install();
        const oid = f.object('PRIVATE SUBJECT\n$(touch PWNED)\nPRIVATE BODY\u001b[31m');
        const other = f.object('another object');
        assert.equal(f.git(['update-ref', ref, oid]).stderr, notice);
        assert.equal(f.git(['update-ref', ref, other]).stderr, notice);
        assert.equal(f.git(['update-ref', 'refs/bell/event/codex/message-1/read-1', oid]).stderr, '');
        assert.equal(f.git(['update-ref', '-d', ref]).stderr, '');
        assert.equal(f.git(['for-each-ref', '--format=%(refname)', 'refs/bell/']).stdout.trim(),
            'refs/bell/event/codex/message-1/read-1');
        assert.equal(existsSync(join(f.cwd, 'PWNED')), false);
    });
}

test('real Git batches notify once and aborted transactions stay silent', t => {
    const f = fixture(t);
    f.configure('codex');
    f.install();
    const oid = f.object();
    const batch = `start\ncreate ${ref} ${oid}\ncreate refs/bell/inbox/all/broadcast-1 ${oid}\nprepare\ncommit\n`;
    assert.equal(f.git(['update-ref', '--stdin'], { input: batch }).stderr, notice);
    const abort = `start\ncreate refs/bell/inbox/codex/aborted-1 ${oid}\nprepare\nabort\n`;
    assert.equal(f.git(['update-ref', '--stdin'], { input: abort }).stderr, '');
    assert.equal(f.git(['for-each-ref', '--format=%(refname)', 'refs/bell/inbox/codex/aborted-1']).stdout, '');
});

test('real Git linked worktree uses shared configured reader, not sender environment', t => {
    const f = fixture(t);
    f.configure('codex');
    const oid = f.object();
    f.git(['update-ref', 'refs/heads/main', oid]);
    const linked = join(f.root, 'linked worktree');
    f.git(['worktree', 'add', '-q', '--detach', linked, oid]);
    f.install();
    const result = f.git(['-C', linked, 'update-ref', ref, oid], {
        env: { ...f.env, BELL_AS: 'claude', YOGIT_AS: 'claude', CLAUDECODE: '1' },
    });
    assert.equal(result.stderr, notice);
    assert.equal(f.git(['rev-parse', '--verify', ref]).stdout.trim(), oid);
});

test('real Git bare repository and custom hooksPath work', t => {
    const f = fixture(t, { bare: true });
    f.configure('codex');
    f.git(['config', '--local', 'core.hooksPath', join(f.root, 'custom hooks')]);
    f.install();
    const oid = f.object();
    assert.equal(f.git(['update-ref', ref, oid]).stderr, notice);
});

test('real Git with no opt-in still succeeds silently and starts no yogit process', t => {
    const f = fixture(t);
    const bin = join(f.root, 'bin');
    mkdirSync(bin);
    const sentinel = join(f.root, 'yogit-was-run');
    writeFileSync(join(bin, 'yogit'), '#!/bin/sh\nprintf unexpected > "$YOGIT_SENTINEL"\nexit 1\n', { mode: 0o755 });
    f.env.PATH = `${bin}:${f.env.PATH}`;
    f.env.YOGIT_SENTINEL = sentinel;
    f.install();
    const oid = f.object();
    assert.equal(f.git(['update-ref', ref, oid]).stderr, '');
    f.configure('codex');
    assert.equal(f.git(['update-ref', 'refs/bell/inbox/codex/message-2', oid]).stderr, notice);
    assert.equal(existsSync(sentinel), false);
});


test('real Git local fetch announces arrival without writing lifecycle events', t => {
    const sender = fixture(t);
    const reader = fixture(t);
    const oid = sender.object('UNTRUSTED SUBJECT AND BODY');
    sender.git(['update-ref', ref, oid]);
    reader.configure('codex');
    reader.install();
    const result = reader.git(['fetch', '--no-tags', sender.cwd,
        '+refs/bell/inbox/*:refs/bell/inbox/*']);
    assert.equal(result.stderr.split(notice).length - 1, 1);
    assert.equal(result.stderr.includes('UNTRUSTED SUBJECT AND BODY'), false);
    assert.equal(reader.git(['rev-parse', '--verify', ref]).stdout.trim(), oid);
    assert.equal(reader.git(['for-each-ref', '--format=%(refname)', 'refs/bell/event/']).stdout, '');
    assert.equal(reader.git(['for-each-ref', '--format=%(refname)', 'refs/bell/ack/']).stdout, '');
});
