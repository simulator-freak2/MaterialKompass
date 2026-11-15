const crypto = require('node:crypto');

const REFRESH_TOKEN_TTL_MS = 30 * 24 * 60 * 60 * 1000;
const MAX_SESSIONS_PER_USER = 10;
// Eine Anmeldung endet nach 60 Minuten ohne Nutzeraktivitaet. Danach sind
// Access- und Refresh-Token dieser Sitzung wertlos.
const INACTIVITY_TIMEOUT_MS = 60 * 60 * 1000;
// lastActivityAt wird hoechstens einmal pro Minute fortgeschrieben und
// hoechstens alle fuenf Minuten aktiv persistiert.
const ACTIVITY_UPDATE_INTERVAL_MS = 60 * 1000;
const ACTIVITY_PERSIST_INTERVAL_MS = 5 * 60 * 1000;

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
  inactivityTimeoutMs = INACTIVITY_TIMEOUT_MS,
  now = Date.now,
}) {
  const activityPersistedAt = new Map();

  function lastActivity(session) {
    const value = Date.parse(session.lastActivityAt || session.lastUsedAt || session.createdAt);
    return Number.isFinite(value) ? value : 0;
  }

  function inactive(session, timestamp = now()) {
    return timestamp - lastActivity(session) >= inactivityTimeoutMs;
  }

  function removeAt(index) {
    activityPersistedAt.delete(sessions[index].id);
    sessions.splice(index, 1);
  }

  function prune() {
    const timestamp = now();
    for (let index = sessions.length - 1; index >= 0; index -= 1) {
      if (Date.parse(sessions[index].expiresAt) <= timestamp
          || inactive(sessions[index], timestamp)) {
        removeAt(index);
      }
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
    // Device sessions must end when an administrator resets or reconfigures
    // the device; the access-token check (dsv) alone does not cover refresh.
    if (Number.isInteger(context.deviceSecurityVersion)) {
      normalized.deviceSecurityVersion = context.deviceSecurityVersion;
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
      lastActivityAt: timestamp,
      expiresAt: new Date(now() + REFRESH_TOKEN_TTL_MS).toISOString(),
    });
    return {
      token: createToken(user, { ...tokenContext, sessionId: id }),
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
    // Ein Refresh ist keine Nutzeraktivitaet: Er prueft die Inaktivitaet,
    // verlaengert sie aber nicht.
    if (inactive(session)) {
      const index = sessions.indexOf(session);
      if (index >= 0) removeAt(index);
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
      token: createToken(user, { ...tokenContext, sessionId: session.id }),
      refreshToken: nextRefreshToken,
      expiresIn: 3600,
      user,
    };
  }

  function revokeAll(userId) {
    for (let index = sessions.length - 1; index >= 0; index -= 1) {
      if (sessions[index].userId === userId) removeAt(index);
    }
  }

  /**
   * Prueft bei jeder authentifizierten Anfrage, ob die Sitzung des Access-Tokens
   * noch besteht, und schreibt die Nutzeraktivitaet fort. Hintergrundabfragen
   * (Polling, automatische Synchronisierung) halten die Sitzung nicht offen.
   *
   * @returns {{ active: boolean, persist: boolean }}
   */
  function touch(sessionId, { userId, background = false } = {}) {
    const index = sessions.findIndex((entry) => entry.id === sessionId);
    const session = index >= 0 ? sessions[index] : null;
    if (!session || session.userId !== userId) return { active: false, persist: false };
    const timestamp = now();
    if (Date.parse(session.expiresAt) <= timestamp || inactive(session, timestamp)) {
      removeAt(index);
      return { active: false, persist: true };
    }
    if (background || timestamp - lastActivity(session) < ACTIVITY_UPDATE_INTERVAL_MS) {
      return { active: true, persist: false };
    }
    session.lastActivityAt = new Date(timestamp).toISOString();
    const persistedAt = activityPersistedAt.get(session.id) || 0;
    if (timestamp - persistedAt < ACTIVITY_PERSIST_INTERVAL_MS) {
      return { active: true, persist: false };
    }
    activityPersistedAt.set(session.id, timestamp);
    return { active: true, persist: true };
  }

  return { issue, rotate, revokeAll, touch };
}

module.exports = {
  ACTIVITY_PERSIST_INTERVAL_MS,
  ACTIVITY_UPDATE_INTERVAL_MS,
  INACTIVITY_TIMEOUT_MS,
  createAuthSessions,
};
