const fs = require('node:fs');

const file = process.argv[2];
const minimum = Number(process.argv[3]);
if (!file || !Number.isFinite(minimum) || minimum < 0 || minimum > 100) {
  console.error('Aufruf: node tool/check_lcov.js <lcov.info> <minimum-prozent>');
  process.exit(2);
}

const content = fs.readFileSync(file, 'utf8');
let found = 0;
let hit = 0;
for (const line of content.split(/\r?\n/)) {
  if (line.startsWith('LF:')) found += Number(line.slice(3)) || 0;
  if (line.startsWith('LH:')) hit += Number(line.slice(3)) || 0;
}
if (found === 0) {
  console.error('Der Coverage-Bericht enthält keine instrumentierten Dart-Zeilen.');
  process.exit(1);
}
const percent = (hit / found) * 100;
console.log(`Flutter-Linienabdeckung: ${percent.toFixed(2)} % (${hit}/${found}), Minimum ${minimum.toFixed(2)} %.`);
if (percent + Number.EPSILON < minimum) process.exitCode = 1;
