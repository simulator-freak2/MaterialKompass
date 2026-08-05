const test = require('node:test');
const assert = require('node:assert/strict');
const { createApp } = require('../src/app');

async function setup() {
  const sent = [];
  const snapshots = [];
  const app = createApp({
    accountMailSender: async (message) => {
      sent.push(message);
      return true;
    },
    dataStore: {
      async saveCollections(snapshot) { snapshots.push(snapshot); },
    },
  });
  const server = await new Promise((resolve) => {
    const instance = app.listen(0, '127.0.0.1', () => resolve(instance));
  });
  const baseUrl = `http://127.0.0.1:${server.address().port}`;
  async function request(path, { method = 'GET', token, body } = {}) {
    const response = await fetch(`${baseUrl}${path}`, {
      method,
      headers: {
        'Content-Type': 'application/json',
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
      },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    return {
      response,
      data: response.status === 204 ? null : await response.json(),
    };
  }
  const login = await request('/api/auth/login', {
    method: 'POST',
    body: { identifier: 'admin', password: 'MaterialKompass2026!' },
  });
  return { server, request, token: login.data.token, sent, snapshots };
}

test('admins manage persistent mail templates and defaults are used for account mail', async () => {
  const { server, request, token, sent, snapshots } = await setup();
  try {
    const createdTemplate = await request('/api/mail/templates', {
      method: 'POST',
      token,
      body: {
        name: 'Willkommen',
        subject: 'Willkommen bei MaterialKompass',
        content: '**Persönliche Begrüßung**',
        format: 'markdown',
        purpose: 'user-create',
        placement: 'before-action',
        defaultFor: 'user-create',
      },
    });
    assert.equal(createdTemplate.response.status, 201);
    assert.equal(snapshots.at(-1).mailTemplates.length, 1);

    const createdUser = await request('/api/users', {
      method: 'POST',
      token,
      body: {
        username: 'mail-test',
        email: 'mail-test@example.org',
        password: 'SehrSicher123!',
        roles: ['Nutzer'],
      },
    });
    assert.equal(createdUser.response.status, 201);
    assert.equal(sent.at(-1).customMessage.content, '**Persönliche Begrüßung**');
    assert.equal(sent.at(-1).customMessage.placement, 'before-action');

    const listed = await request('/api/mail/templates', { token });
    assert.equal(listed.response.status, 200);
    assert.equal(listed.data[0].defaultFor, 'user-create');

    assert.equal((await request(`/api/mail/templates/${createdTemplate.data.id}`, {
      method: 'DELETE', token,
    })).response.status, 204);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});

test('admins send free mails and can add a one-off password reset message', async () => {
  const { server, request, token, sent } = await setup();
  try {
    const freeMail = await request('/api/mail/send', {
      method: 'POST',
      token,
      body: {
        to: 'empfang@example.org',
        subject: 'Individueller Hinweis',
        content: '<p>Hallo <strong>Team</strong></p>',
        format: 'html',
      },
    });
    assert.equal(freeMail.response.status, 202);
    assert.equal(sent.at(-1).richContent.format, 'html');

    const reset = await request('/api/users/user-admin/password-reset', {
      method: 'POST',
      token,
      body: {
        mailMessage: {
          content: 'Bitte melde dich bei Rückfragen.',
          format: 'markdown',
          placement: 'after-action',
        },
      },
    });
    assert.equal(reset.response.status, 202);
    assert.equal(sent.at(-1).customMessage.placement, 'after-action');
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});

test('mail administration rejects unauthenticated access and invalid HTML metadata', async () => {
  const { server, request, token } = await setup();
  try {
    assert.equal((await request('/api/mail/templates')).response.status, 401);
    const invalid = await request('/api/mail/templates', {
      method: 'POST',
      token,
      body: {
        name: 'Ungültig',
        content: 'Text',
        format: 'script',
      },
    });
    assert.equal(invalid.response.status, 400);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});
