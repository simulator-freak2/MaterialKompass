const crypto = require('node:crypto');

const REFRESH_TOKEN_TTL_MS = 30 * 24 * 60 * 60 * 1000;
const MAX_SESSIONS_PER_USER = 10;

function tokenHash(value) {
  return crypto.createHash('sha256').update(value).digest('base64url');
}

function createAuthSessions({
  sessions,
  users,
  createToken,
  securityVersion,
  loginAccessAllowed,
  sessionContextAllowed = () => true,
  now = Date.now,
}) {
  function prune() {
    const timestamp = now();
    for (let index = sessions.length - 1; index >= 0; index -= 1) {
      if (Date.parse(sessions[index].expiresAt) <= timestamp) sessions.splice(index, 1);
    }
  }

  function createRefreshValue(id) {
    return `${id}.${crypto.randomBytes(32).toString('base64url')}`;
  }

  function parseRefreshValue(value) {
    if (typeof value !== 'string' || value.length > 256) return null;
    const separator = value.indexOf('.');
    if (separator < 1 || separator === value.length - 1) return null;
    return { id: value.slice(0, separator), secret: value.slice(separator + 1) };
  }

  function safeHashEqual(left, right) {
    const leftBuffer = Buffer.from(String(left));
    const rightBuffer = Buffer.from(String(right));
    return leftBuffer.length === rightBuffer.length
      && crypto.timingSafeEqual(leftBuffer, rightBuffer);
  }

  function enforceUserLimit(userId) {
    const userSessions = sessions
      .filter((entry) => entry.userId === userId)
      .sort((left, right) => Date.parse(left.lastUsedAt) - Date.parse(right.lastUsedAt));
    while (userSessions.length >= MAX_SESSIONS_PER_USER) {
      const oldest = userSessions.shift();
      const index = sessions.findIndex((entry) => entry.id === oldest.id);
      if (index >= 0) sessions.splice(index, 1);
    }
  }

  function normalizedTokenContext(context = {}) {
    const normalized = {};
    for (const key of ['deviceId', 'sessionType', 'organizationId', 'unitId']) {
      if (typeof context[key] === 'string' && context[key]) {
        normalized[key] = context[key];
      }
    }
    return normalized;
  }

  function issue(user, context = {}) {
    prune();
    enforceUserLimit(user.id);
    const id = crypto.randomUUID();
    const refreshToken = createRefreshValue(id);
    const timestamp = new Date(now()).toISOString();
    const tokenContext = normalizedTokenContext(context);
    sessions.push({
      id,
      userId: user.id,
      refreshTokenHash: tokenHash(refreshToken),
      securityVersion: securityVersion(user),
      tokenContext,
      createdAt: timestamp,
      lastUsedAt: timestamp,
      expiresAt: new Date(now() + REFRESH_TOKEN_TTL_MS).toISOString(),
    });
    return {
      token: createToken(user, tokenContext),
      refreshToken,
      expiresIn: 3600,
    };
  }

  function rotate(refreshToken, requestContext = {}) {
    prune();
    const parsed = parseRefreshValue(refreshToken);
    if (!parsed) return null;
    const session = sessions.find((entry) => entry.id === parsed.id);
    if (!session || !safeHashEqual(session.refreshTokenHash, tokenHash(refreshToken))) {
      return null;
    }
    const user = users.find((entry) => entry.id === session.userId);
    const tokenContext = normalizedTokenContext(session.tokenContext);
    if (!user?.active || !user.emailVerifiedAt
        || !loginAccessAllowed(user, tokenContext.deviceId)
        || !sessionContextAllowed(user, tokenContext, requestContext)
        || session.securityVersion !== securityVersion(user)) {
      const index = sessions.indexOf(session);
      if (index >= 0) sessions.splice(index, 1);
      return null;
    }
    const nextRefreshToken = createRefreshValue(session.id);
    session.refreshTokenHash = tokenHash(nextRefreshToken);
    session.lastUsedAt = new Date(now()).toISOString();
    return {
      token: createToken(user, tokenContext),
      refreshToken: nextRefreshToken,
      expiresIn: 3600,
      user,
    };
  }

  function revokeAll(userId) {
    for (let index = sessions.length - 1; index >= 0; index -= 1) {
      if (sessions[index].userId === userId) sessions.splice(index, 1);
    }
  }

  return { issue, rotate, revokeAll };
}

module.exports = { createAuthSessions };
