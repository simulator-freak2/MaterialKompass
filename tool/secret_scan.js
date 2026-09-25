const { execFileSync } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');

const forbiddenNames = [
  /(^|\/)\.env$/i,
  /(^|\/)key\.properties$/i,
  /\.(?:jks|keystore|p12|pfx|pem|key)$/i,
];
const signatures = [
  ['privater Schlüssel', /-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/],
  ['GitHub-Token', /\bgh[oprsu]_[A-Za-z0-9_]{30,}\b/],
  ['AWS-Zugriffsschlüssel', /\b(?:AKIA|ASIA)[A-Z0-9]{16}\b/],
  ['Slack-Token', /\bxox[baprs]-[A-Za-z0-9-]{20,}\b/],
  ['Google-API-Schlüssel', /\bAIza[0-9A-Za-z_-]{35}\b/],
];

const repositoryFiles = execFileSync(
  'git',
  ['ls-files', '--cached', '--others', '--exclude-standard', '-z'],
  { encoding: 'utf8' },
)
  .split('\0')
  .filter(Boolean);
const findings = [];

for (const relative of repositoryFiles) {
  const normalized = relative.replaceAll('\\', '/');
  if (forbiddenNames.some((pattern) => pattern.test(normalized))
      && !normalized.endsWith('.env.example')) {
    findings.push(`${relative}: vertraulicher Dateityp ist versioniert`);
    continue;
  }
  const absolute = path.resolve(relative);
  const stat = fs.statSync(absolute);
  if (stat.size > 2 * 1024 * 1024) continue;
  const bytes = fs.readFileSync(absolute);
  if (bytes.includes(0)) continue;
  const content = bytes.toString('utf8');
  for (const [label, pattern] of signatures) {
    if (pattern.test(content)) findings.push(`${relative}: möglicher ${label}`);
  }
}

if (findings.length) {
  console.error('Secret-Prüfung fehlgeschlagen:');
  findings.forEach((finding) => console.error(`- ${finding}`));
  process.exitCode = 1;
} else {
  console.log(`${repositoryFiles.length} Repository-Dateien ohne bekannte Secret-Signatur geprüft.`);
}
