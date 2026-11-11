const { PLATFORM_ORGANIZATION_ID } = require('./platform-administration');
const crypto = require('node:crypto');
const { normalizeIdentifier } = require('./user-identity');

const hash = (value) => crypto.createHash('sha256').update(String(value || '')).digest('hex');
// The raw token is not retained. A database/backup copy therefore cannot use
// this binding as an offline dictionary oracle for the recipient's email.
const recipientBinding = (token, email) => crypto.createHmac('sha256', token)
  .update(normalizeIdentifier(email)).digest('hex');
const INVITATION_TTL_MS = 7 * 24 * 60 * 60 * 1000;

function registerMembershipInvitations({ app, users, memberships, organizations,
  organizationUnits, authMiddleware, requirePermission, authRateLimit,
  requestedScopes, writableUnitIds, findUser, accountMailSender, onTokenIssued,
  logEvent, now = Date.now }) {
  function membershipFor(userId, organizationId) {
    return memberships.find((entry) => entry.userId === userId && entry.organizationId === organizationId);
  }

  function mergeAccess(user, organizationId, access) {
    let membership = membershipFor(user.id, organizationId);
    if (!membership) {
      membership = {
        id: `membership-${crypto.randomUUID()}`, userId: user.id, organizationId,
        status: 'inactive', scopes: [], defaultUnitId: null,
        createdAt: new Date(now()).toISOString(),
      };
      memberships.push(membership);
    }
    const existing = membership.scopes || [];
    // Adding a membership must never silently replace existing permissions.
    if (access.scopes.some((scope) => existing.some((entry) => entry.unitId === scope.unitId))) {
      return { error: 'Mindestens ein Bereich ist bereits freigegeben. Verwenden Sie „Bereichsrechte bearbeiten“.' };
    }
    membership.scopes = [...existing, ...structuredClone(access.scopes)];
    membership.status = 'active';
    membership.defaultUnitId ||= access.defaultUnitId;
    return { membership };
  }

  function pendingFor(req) {
    const allowed = writableUnitIds(req);
    return memberships.filter((entry) => entry.organizationId === req.tenant.organizationId)
      .flatMap((membership) => (membership.invitations || []).map((invitation) => ({ membership, invitation })))
      .filter(({ invitation }) => invitation.status === 'pending'
        && Date.parse(invitation.expiresAt) > now()
        && invitation.scopes.every((scope) => allowed.has(scope.unitId)));
  }

  function lookup(token) {
    if (typeof token !== 'string' || !/^[a-f0-9]{64}$/.test(token)) return null;
    const tokenHash = hash(token);
    for (const membership of memberships) {
      if (membership.organizationId === PLATFORM_ORGANIZATION_ID) continue;
      const invitation = (membership.invitations || []).find((entry) =>
        entry.status === 'pending' && entry.tokenHash === tokenHash && Date.parse(entry.expiresAt) > now());
      if (!invitation) continue;
      const user = users.find((entry) => entry.id === membership.userId && entry.active && !entry.identityErased);
      const organization = organizations.find((entry) => entry.id === membership.organizationId && entry.status === 'active');
      if (!user || !organization || recipientBinding(token, user.email) !== invitation.recipientBinding) return null;
      return { membership, invitation, user, organization };
    }
    return null;
  }

  app.post('/api/users/memberships', authMiddleware, requirePermission('users.write'), async (req, res) => {
    if (req.tenant.organizationId === PLATFORM_ORGANIZATION_ID) return res.status(403).json({ error: 'Mitglieder der zentralen Verwaltung werden ausschließlich aus den Plattformadministratoren abgeleitet.' });
    const mode = req.body.mode || 'direct';
    if (!['direct', 'invitation'].includes(mode)) return res.status(400).json({ error: 'Ungültige Aufnahmeart.' });
    const access = requestedScopes(req);
    if (access.error) return res.status(400).json({ error: access.error });
    const user = findUser(req.body.identifier);
    // An exact identifier is required; never expose global search results.
    if (!user?.active) {
      if (mode === 'invitation') return res.status(202).json({ message: 'Wenn ein aktives eindeutiges Konto vorhanden ist, wird eine Einladung versendet.' });
      return res.status(404).json({ error: 'Kein aktives eindeutiges Nutzerkonto gefunden.' });
    }
    if (mode === 'direct') {
      const result = mergeAccess(user, req.tenant.organizationId, access);
      if (result.error) return res.status(409).json({ error: result.error });
      logEvent('membership_access_added', 'User', { id: user.id }, req.user.username);
      // The actor does not gain visibility of account security settings.
      return res.status(201).json({ message: 'Die Bereichsrechte wurden freigegeben.' });
    }
    if (normalizeIdentifier(req.body.identifier) !== normalizeIdentifier(user.email)) {
      return res.status(400).json({ error: 'Für eine Einladung ist die genaue E-Mail-Adresse erforderlich.' });
    }
    let membership = membershipFor(user.id, req.tenant.organizationId);
    if (!membership) {
      membership = { id: `membership-${crypto.randomUUID()}`, userId: user.id,
        organizationId: req.tenant.organizationId, status: 'invited', scopes: [],
        defaultUnitId: null, createdAt: new Date(now()).toISOString() };
      memberships.push(membership);
    }
    membership.invitations ||= [];
    // Bound retained invitation history; pending entries are not evicted.
    membership.invitations = membership.invitations.filter((entry) =>
      entry.status === 'pending' && Date.parse(entry.expiresAt) > now());
    if (membership.invitations.length >= 10) return res.status(409).json({ error: 'Bitte zuerst offene Einladungen widerrufen.' });
    const token = crypto.randomBytes(32).toString('hex');
    const invitation = {
      id: crypto.randomUUID(), status: 'pending', tokenHash: hash(token),
      recipientBinding: recipientBinding(token, user.email), actorId: req.user.id,
      actorMembershipId: req.tenant.membershipId,
      scopes: structuredClone(access.scopes), defaultUnitId: access.defaultUnitId,
      expiresAt: new Date(now() + INVITATION_TTL_MS).toISOString(),
    };
    membership.invitations.push(invitation);
    const organization = organizations.find((entry) => entry.id === membership.organizationId);
    const url = `${process.env.APP_BASE_URL || 'https://materialkompass.org'}/#/membership-invitation?token=${token}`;
    try {
      await app.locals.persistData();
      const sent = await accountMailSender({ to: user.email, subject: 'Einladung zu MaterialKompass',
        text: `Sie wurden von ${organization?.name || 'einer Organisation'} eingeladen. Prüfen Sie die Bereiche und stimmen Sie innerhalb von sieben Tagen ausdrücklich zu:\n\n${url}\n\nOhne Zustimmung entstehen keine zusätzlichen Rechte.`,
        actionUrl: url, actionLabel: 'Einladung prüfen' });
      if (sent === false) throw new Error('Kein Mailtransport verfügbar.');
    } catch (error) {
      invitation.status = 'revoked';
      delete invitation.tokenHash;
      await app.locals.persistData();
      return res.status(503).json({ error: 'Die Einladung konnte nicht versendet werden. Bitte erneut versuchen.' });
    }
    onTokenIssued?.({ type: 'membership-invitation', userId: user.id, token });
    logEvent('membership_invited', 'User', { id: user.id, invitationId: invitation.id }, req.user.username);
    return res.status(202).json({ message: 'Wenn ein aktives eindeutiges Konto vorhanden ist, wird eine Einladung versendet.' });
  });

  app.get('/api/users/invitations', authMiddleware, requirePermission('users.write'), (req, res) => {
    return res.json(pendingFor(req).map(({ invitation }) => ({
      id: invitation.id, expiresAt: invitation.expiresAt,
      scopes: invitation.scopes.map((scope) => ({ unitId: scope.unitId, roles: scope.roles })),
    })));
  });

  app.delete('/api/users/invitations/:id', authMiddleware, requirePermission('users.write'), (req, res) => {
    const record = pendingFor(req).find(({ invitation }) => invitation.id === req.params.id);
    if (!record) return res.status(404).json({ error: 'Einladung nicht gefunden.' });
    record.invitation.status = 'revoked';
    delete record.invitation.tokenHash;
    logEvent('membership_invitation_revoked', 'User', { id: record.membership.userId }, req.user.username);
    return res.status(204).end();
  });

  app.get('/api/auth/membership-invitation', authRateLimit, (req, res) => {
    res.setHeader('Cache-Control', 'no-store');
    const record = lookup(req.query.token);
    if (!record) return res.status(400).json({ error: 'Die Einladung ist ungültig oder abgelaufen.' });
    return res.json({ organization: record.organization.name, expiresAt: record.invitation.expiresAt,
      scopes: record.invitation.scopes.map((scope) => ({
        unit: organizationUnits.find((unit) => unit.id === scope.unitId)?.name || scope.unitId,
        roles: scope.roles,
      })) });
  });

  app.post('/api/auth/membership-invitation/confirm', authRateLimit, async (req, res) => {
    const record = lookup(req.body.token);
    if (!record) return res.status(400).json({ error: 'Die Einladung ist ungültig oder abgelaufen.' });
    if (typeof req.body.accept !== 'boolean') return res.status(400).json({ error: 'Bitte zustimmen oder ablehnen.' });
    const { invitation, membership, user } = record;
    if (req.body.accept) {
      const actor = users.find((entry) => entry.id === invitation.actorId && entry.active && entry.emailVerifiedAt);
      const actorMembership = memberships.find((entry) => entry.id === invitation.actorMembershipId
        && entry.userId === invitation.actorId && entry.organizationId === membership.organizationId && entry.status === 'active');
      const checkRequest = { tenant: { organizationId: membership.organizationId,
        membershipId: actorMembership?.id }, body: { scopes: invitation.scopes, defaultUnitId: invitation.defaultUnitId } };
      const access = actor && actorMembership && requestedScopes(checkRequest);
      if (!access || access.error) return res.status(409).json({ error: 'Die Freigabe ist nicht mehr zulässig. Bitte eine neue Einladung anfordern.' });
      const result = mergeAccess(user, membership.organizationId, access);
      if (result.error) return res.status(409).json({ error: result.error });
    }
    // Consume before yielding so parallel confirmations cannot reuse the token.
    invitation.status = req.body.accept ? 'accepted' : 'declined';
    delete invitation.tokenHash;
    req.persistenceRequired = true;
    await app.locals.persistData();
    logEvent(`membership_invitation_${invitation.status}`, 'User', { id: user.id }, user.username);
    return res.json({ message: req.body.accept ? 'Die Bereichsrechte wurden aktiviert.' : 'Die Einladung wurde abgelehnt.' });
  });
}

module.exports = { registerMembershipInvitations };
