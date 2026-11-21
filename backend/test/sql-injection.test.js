const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const { createUserStore } = require('../src/db/user-store');

const SOURCE_ROOT = path.join(__dirname, '..', 'src');
const QUERY_CALL = /\.(query|batch|execute)\(\s*(`(?:\\[\s\S]|[^`\\])*`|'(?:\\.|[^'\\])*'|"(?:\\.|[^"\\])*")\s*(\+)?/g;
// The only interpolation allowed in SQL text is a generated list of "?" placeholders.
const ALLOWED_INTERPOLATIONS = new Set(['${placeholders}']);

function sourceFiles(directory) {
  return fs.readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const fullPath = path.join(directory, entry.name);
    if (entry.isDirectory()) return sourceFiles(fullPath);
    return entry.name.endsWith('.js') ? [fullPath] : [];
  });
}

test('SQL statements never interpolate or concatenate input values', () => {
  const violations = [];
  for (const file of sourceFiles(SOURCE_ROOT)) {
    const source = fs.readFileSync(file, 'utf8');
    for (const match of source.matchAll(QUERY_CALL)) {
      const line = source.slice(0, match.index).split('\n').length;
      const location = `${path.relative(SOURCE_ROOT, file)}:${line}`;
      if (match[3]) violations.push(`${location} concatenates SQL text`);
      for (const interpolation of match[2].match(/\$\{[^}]*\}/g) || []) {
        if (!ALLOWED_INTERPOLATIONS.has(interpolation)) {
          violations.push(`${location} interpolates ${interpolation}`);
        }
      }
    }
  }
  assert.deepEqual(violations, [], 'Use "?" placeholders and pass values as parameters.');
});

test('placeholder lists consist only of "?" markers', () => {
  const source = fs.readFileSync(path.join(SOURCE_ROOT, 'db', 'user-store.js'), 'utf8');
  for (const [, expression] of source.matchAll(/const placeholders = (.+);/g)) {
    assert.equal(expression, "names.map(() => '?').join(', ')");
  }
});

test('the MariaDB pool forbids multiple statements per query', () => {
  let poolOptions;
  createUserStore({
    createPool(options) {
      poolOptions = options;
      return { async query() { return []; }, async end() {} };
    },
  });
  assert.equal(poolOptions.multipleStatements, false);
  assert.equal(poolOptions.namedPlaceholders, false);
});
