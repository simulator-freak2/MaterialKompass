// Email addresses and login names share one namespace: either can be used
// at login. Keep this normalization identical for every account write.
function normalizeIdentifier(value) {
  return String(value || '').trim().toLowerCase();
}

function identityConflict(users, { id, username, email }) {
  const keys = new Set([normalizeIdentifier(username), normalizeIdentifier(email)]);
  keys.delete('');
  return users.some((user) => user.id !== id && !user.identityErased
    && [user.username, user.email].some((value) => keys.has(normalizeIdentifier(value))));
}

function identityConflicts(users) {
  const owners = new Map();
  for (const user of users) {
    if (user.identityErased) continue;
    for (const key of new Set([user.username, user.email].map(normalizeIdentifier))) {
      if (!key) continue;
      if (!owners.has(key)) owners.set(key, new Set());
      owners.get(key).add(user.id);
    }
  }
  // Report IDs only; do not create another plaintext copy of identities.
  return [...owners.values()].filter((ids) => ids.size > 1)
    .map((ids) => ({ userIds: [...ids].sort() }));
}

module.exports = { normalizeIdentifier, identityConflict, identityConflicts };
