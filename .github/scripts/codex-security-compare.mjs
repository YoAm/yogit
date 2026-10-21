// Compare two Codex Security canonical findings.json files (the CLI scan and
// the plugin-skills scan of the same change) and print overlap COUNTS only:
// no titles, rule ids, paths or lines, because yogit's step summaries are
// public.
//
// Two findings match when they share a file path and their line ranges
// overlap within LINE_SLACK lines. Matching is greedy and one-to-one, so
// counts are approximate; the archived files on the runner are authoritative.
import { existsSync, readFileSync } from 'node:fs';

const LINE_SLACK = 15;

export function loadFindings(file) {
  if (!file || !existsSync(file)) return null;
  try {
    const doc = JSON.parse(readFileSync(file, 'utf8'));
    return Array.isArray(doc.findings) ? doc.findings : null;
  } catch {
    return null;
  }
}

function spans(finding) {
  return (finding.locations ?? [])
    .filter((l) => typeof l?.path === 'string')
    .map((l) => ({
      path: l.path,
      start: Number(l.startLine ?? l.endLine ?? 0),
      end: Number(l.endLine ?? l.startLine ?? 0),
    }));
}

export function matches(a, b) {
  for (const x of spans(a)) {
    for (const y of spans(b)) {
      if (x.path !== y.path) continue;
      if (x.start - LINE_SLACK <= y.end && y.start - LINE_SLACK <= x.end) return true;
    }
  }
  return false;
}

export function compare(cli, skills) {
  const used = new Set();
  let both = 0;
  for (const a of cli) {
    const j = skills.findIndex((b, i) => !used.has(i) && matches(a, b));
    if (j >= 0) {
      used.add(j);
      both += 1;
    }
  }
  return { both, cliOnly: cli.length - both, skillsOnly: skills.length - both };
}

function severityCounts(findings) {
  const counts = { critical: 0, high: 0, medium: 0, low: 0, other: 0 };
  for (const f of findings) {
    const level = String(f.severity?.level ?? f.severity ?? '').toLowerCase();
    counts[level in counts ? level : 'other'] += 1;
  }
  return counts;
}

function main() {
  const [cliFile, skillsFile] = process.argv.slice(2);
  const cli = loadFindings(cliFile);
  const skills = loadFindings(skillsFile);
  const fmt = (list) => (list ? String(list.length) : 'UNQUERIED');

  console.log('### Codex Security: CLI vs plugin skills (advisory)');
  console.log('');
  console.log('| Source | Findings | critical | high | medium | low |');
  console.log('| --- | ---: | ---: | ---: | ---: | ---: |');
  for (const [name, list] of [['CLI scan', cli], ['plugin skills', skills]]) {
    if (!list) {
      console.log(`| ${name} | UNQUERIED | | | | |`);
      continue;
    }
    const c = severityCounts(list);
    console.log(`| ${name} | ${fmt(list)} | ${c.critical} | ${c.high} | ${c.medium} | ${c.low} |`);
  }
  console.log('');
  if (cli && skills) {
    const r = compare(cli, skills);
    console.log(`Overlap: **${r.both}** in both, ${r.cliOnly} CLI-only, ${r.skillsOnly} skills-only.`);
  } else {
    console.log('Overlap: UNQUERIED (one side produced no findings.json).');
  }
  console.log('');
  console.log('Findings are kept on the private runner only; see docs/codex-security-ci.md.');
}

if (import.meta.url === `file://${process.argv[1]}`) main();
