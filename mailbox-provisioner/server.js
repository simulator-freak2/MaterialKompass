const http = require('node:http');
const { spawn } = require('node:child_process');
const { timingSafeEqual } = require('node:crypto');

const MAX_BODY_BYTES = 16 * 1024;

function safeEqual(left, right) {
  const a = Buffer.from(String(left || ''));
  const b = Buffer.from(String(right || ''));
  return a.length === b.length && timingSafeEqual(a, b);
}

function dockerMailboxCreate({ email, password }, options = {}) {
  const container = options.container || process.env.MAILSERVER_CONTAINER || 'mailserver';
  return new Promise((resolve, reject) => {
    const child = spawn('docker', [
      'exec', '-i', container, 'setup', 'email', 'add', email,
    ], {
      stdio: ['pipe', 'pipe', 'pipe'],
      shell: false,
    });
    let output = '';
    const append = (chunk) => {
      if (output.length < 64 * 1024) output += chunk.toString();
    };
    child.stdout.on('data', append);
    child.stderr.on('data', append);
    child.on('error', reject);
    child.stdin.on('error', () => {});
    const timeout = setTimeout(() => {
      child.kill('SIGKILL');
      reject(new Error('Zeitüberschreitung bei der Postfachanlage.'));
    }, 30_000);
    child.on('close', (code) => {
      clearTimeout(timeout);
      if (code === 0) return resolve();
      const error = new Error(
        /exist|already|duplicate/i.test(output)
          ? 'Das Postfach existiert bereits.'
          : 'docker-mailserver konnte das Postfach nicht anlegen.',
      );
      error.status = /exist|already|duplicate/i.test(output) ? 409 : 502;
      return reject(error);
    });
    // setup reads and confirms the password interactively. Feeding it through
    // stdin keeps the secret out of the process arguments and application logs.
    child.stdin.end(`${password}\n${password}\n`);
  });
}

function createProvisionerServer(options = {}) {
  const token = options.token ?? process.env.MAILBOX_PROVISIONER_TOKEN;
  const domain = String(
    options.domain ?? process.env.SCANNER_EMAIL_DOMAIN ?? 'materialkompass.org',
  ).trim().toLowerCase().replace(/^@/, '');
  const createMailbox = options.createMailbox || dockerMailboxCreate;
  if (!token || token.length < 32) {
    throw new Error('MAILBOX_PROVISIONER_TOKEN muss mindestens 32 Zeichen lang sein.');
  }
  if (!/^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$/.test(domain)) {
    throw new Error('SCANNER_EMAIL_DOMAIN ist keine gültige E-Mail-Domain.');
  }

  return http.createServer((req, res) => {
    res.setHeader('Content-Type', 'application/json; charset=utf-8');
    if (req.method === 'GET' && req.url === '/health') {
      res.statusCode = 200;
      return res.end(JSON.stringify({ status: 'ok' }));
    }
    if (!safeEqual(req.headers.authorization, `Bearer ${token}`)) {
      res.statusCode = 401;
      return res.end(JSON.stringify({ error: 'Authentication required' }));
    }
    if (req.method !== 'POST' || req.url !== '/mailboxes') {
      res.statusCode = 404;
      return res.end(JSON.stringify({ error: 'Not found' }));
    }

    let body = '';
    req.on('data', (chunk) => {
      body += chunk;
      if (Buffer.byteLength(body) > MAX_BODY_BYTES) req.destroy();
    });
    req.on('end', async () => {
      let data;
      try {
        data = JSON.parse(body);
      } catch (_) {
        res.statusCode = 400;
        return res.end(JSON.stringify({ error: 'Ungültiges JSON.' }));
      }
      const email = String(data.email || '').trim().toLowerCase();
      const password = String(data.password || '');
      const emailPattern = new RegExp(
        `^[a-z0-9](?:[a-z0-9._-]{0,62}[a-z0-9])?@${domain.replaceAll('.', '\\.')}$`,
      );
      if (!emailPattern.test(email) || password.length < 16 || password.length > 256) {
        res.statusCode = 400;
        return res.end(JSON.stringify({ error: 'Postfachdaten sind ungültig.' }));
      }
      try {
        await createMailbox({ email, password }, {
          container: options.container,
        });
        res.statusCode = 201;
        return res.end(JSON.stringify({ email, created: true }));
      } catch (error) {
        res.statusCode = error.status || 502;
        return res.end(JSON.stringify({ error: error.message }));
      }
    });
    return undefined;
  });
}

if (require.main === module) {
  const server = createProvisionerServer();
  server.listen(
    Number(process.env.PORT || 3010),
    process.env.HOST || '0.0.0.0',
    () => console.log('Mailbox provisioner listening.'),
  );
}

module.exports = { createProvisionerServer, dockerMailboxCreate };
