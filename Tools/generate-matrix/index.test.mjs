import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const fixture = JSON.parse(readFileSync(new URL('../../results/Mac17,7/25G83-1.json', import.meta.url)));
function check(documents, extraArgs = []) {
  const directory = mkdtempSync(join(tmpdir(), 'silicon-audit-matrix-'));
  try {
    for (const [i, doc] of documents.entries()) {
      const dir = join(directory, doc.device.identity);
      mkdirSync(dir, { recursive: true });
      writeFileSync(join(dir, `${doc.environment.os_build}-${i + 1}.json`), JSON.stringify(doc));
    }
    return spawnSync(process.execPath, [fileURLToPath(new URL('index.mjs', import.meta.url)), '--results', directory, '--check', ...extraArgs], { encoding: 'utf8' });
  } finally { rmSync(directory, { recursive: true, force: true }); }
}
function withUnknown(bytes) {
  const doc = structuredClone(fixture);
  doc.unrecognized_keys.push({ id: 'unrecognized.hw.optional.future', display_name: 'Future key', category: 'unrecognized', kind: 'unknown', provenance: 'measured', state: 'value', discovered_by: 'walk', raw: { key: 'hw.optional.future', format: null, length: 2, value_hex: bytes, errno: null } });
  return doc;
}
test('unrecognized raw bytes participate in conflict detection', () => {
  const result = check([withUnknown('0102'), withUnknown('0103')]);
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /1 conflict\(s\)/);
  assert.match(result.stdout, /value_hex/);
});
test('rejected results cannot create conflicts in accepted results', () => {
  const rejected = withUnknown('0103');
  rejected.environment.is_simulator = true;
  const result = check([withUnknown('0102'), rejected]);
  assert.equal(result.status, 1);
  assert.match(result.stdout, /0 conflict\(s\)/);
});
test('duplicate IDs are rejected instead of hiding contradictory facts', () => {
  const doc = structuredClone(fixture);
  doc.facts.push({ ...doc.facts[0] });
  const result = check([doc]);
  assert.equal(result.status, 1);
  assert.match(result.stderr, /duplicate fact id/);
});
test('validation failures never overwrite generated artifacts', () => {
  const matrix = new URL('../../MATRIX.md', import.meta.url);
  const site = new URL('../../site/index.html', import.meta.url);
  const before = [readFileSync(matrix), readFileSync(site)];
  const doc = structuredClone(fixture);
  doc.environment.is_simulator = true;
  assert.equal(check([doc], ['--write']).status, 1);
  assert.deepEqual(readFileSync(matrix), before[0]);
  assert.deepEqual(readFileSync(site), before[1]);
});
