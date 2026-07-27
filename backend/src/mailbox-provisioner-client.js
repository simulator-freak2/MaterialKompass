function createMailboxProvisioner(options = {}) {
  const baseUrl = options.baseUrl || process.env.MAILBOX_PROVISIONER_URL;
  const token = options.token || process.env.MAILBOX_PROVISIONER_TOKEN;

  return {
    async createMailbox({ email, password }) {
      if (!baseUrl || !token) {
        const error = new Error('Die automatische Postfachanlage ist nicht konfiguriert.');
        error.status = 503;
        throw error;
      }
      let response;
      try {
        response = await fetch(new URL('/mailboxes', baseUrl), {
          method: 'POST',
          headers: {
            Authorization: `Bearer ${token}`,
            'Content-Type': 'application/json',
          },
          body: JSON.stringify({ email, password }),
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
