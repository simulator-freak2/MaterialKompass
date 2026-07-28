const http = require('node:http');

function socketRequest({ socketPath, token, body }) {
  return new Promise((resolve, reject) => {
    const request = http.request({
      socketPath,
      path: '/mailboxes',
      method: 'POST',
      headers: {
        Authorization: `Bearer ${token}`,
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(body),
      },
      timeout: 35_000,
    }, (response) => {
      let responseBody = '';
      response.setEncoding('utf8');
      response.on('data', (chunk) => {
        if (responseBody.length <= 64 * 1024) responseBody += chunk;
      });
      response.on('end', () => resolve({
        ok: response.statusCode >= 200 && response.statusCode < 300,
        status: response.statusCode,
        async json() {
          try { return JSON.parse(responseBody); } catch (_) { return {}; }
        },
      }));
    });
    request.on('timeout', () => request.destroy(new Error('Zeitüberschreitung.')));
    request.on('error', reject);
    request.end(body);
  });
}

function createMailboxProvisioner(options = {}) {
  const baseUrl = options.baseUrl || process.env.MAILBOX_PROVISIONER_URL;
  const socketPath = options.socketPath || process.env.MAILBOX_PROVISIONER_SOCKET;
  const token = options.token || process.env.MAILBOX_PROVISIONER_TOKEN;

  return {
    async createMailbox({ email, password }) {
      if ((!socketPath && !baseUrl) || !token) {
        const error = new Error('Die automatische Postfachanlage ist nicht konfiguriert.');
        error.status = 503;
        throw error;
      }
      const body = JSON.stringify({ email, password });
      let response;
      try {
        response = socketPath
          ? await socketRequest({ socketPath, token, body })
          : await fetch(new URL('/mailboxes', baseUrl), {
            method: 'POST',
            headers: {
              Authorization: `Bearer ${token}`,
              'Content-Type': 'application/json',
            },
            body,
            signal: AbortSignal.timeout(35_000),
          });
      } catch (_) {
        const error = new Error('Der Postfachdienst ist nicht erreichbar.');
        error.status = 503;
        throw error;
      }
      const data = await response.json().catch(() => ({}));
      if (!response.ok) {
        const error = new Error(data.error || 'Das Postfach konnte nicht angelegt werden.');
        error.status = response.status;
        throw error;
      }
      return data;
    },
  };
}

module.exports = { createMailboxProvisioner };
