// Print per-severity finding counts from a Codex Security SARIF export as a
// Markdown table. Prints counts only: no rule ids, messages, paths or lines,
// because yogit's step summaries are public.
//
// Severity comes from the rule's GitHub `security-severity` score (the
// highest score among that rule's findings), bucketed the way GitHub code
// scanning does. Counts are therefore approximate; the authoritative gate is
// the scanner's own `--fail-on-severity` exit code.
import { readFileSync } from 'node:fs';

const [file] = process.argv.slice(2);
if (!file) {
  console.error('usage: codex-security-counts.mjs <findings.sarif>');
  process.exit(2);
}

const sarif = JSON.parse(readFileSync(file, 'utf8'));
const counts = { critical: 0, high: 0, medium: 0, low: 0, unscored: 0 };

function bucket(score) {
  if (!Number.isFinite(score)) return 'unscored';
  if (score >= 9) return 'critical';
  if (score >= 7) return 'high';
  if (score >= 4) return 'medium';
  return 'low';
}

for (const run of sarif.runs ?? []) {
  const rules = new Map();
  for (const rule of run.tool?.driver?.rules ?? []) {
    rules.set(rule.id, Number.parseFloat(rule.properties?.['security-severity']));
  }
  for (const result of run.results ?? []) {
    const rule = result.ruleId ?? run.tool?.driver?.rules?.[result.ruleIndex]?.id;
    counts[bucket(rules.get(rule))] += 1;
  }
}

const total = Object.values(counts).reduce((a, b) => a + b, 0);
console.log('### Codex Security (advisory)');
console.log('');
console.log('| Severity | Count |');
console.log('| --- | ---: |');
for (const [name, value] of Object.entries(counts)) console.log(`| ${name} | ${value} |`);
console.log(`| **total** | **${total}** |`);
console.log('');
console.log('Findings are kept on the private runner only; see docs/codex-security-ci.md.');
