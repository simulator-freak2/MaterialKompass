const crypto = require('node:crypto');
const bcrypt = require('bcryptjs');
const { sendAccountMail } = require('./mailer');

const VERIFY_TTL = 24 * 60 * 60 * 1000;
const RESET_TTL = 60 * 60 * 1000;

function normalize(value) {
  return String(value || '').trim().toLowerCase();
}

function tokenHash(token) {
  return crypto.createHash('sha256').update(token).digest('hex');
}

function publicUser(user) {
  const {
    passwordHash,
    verificationTokenHash,
    verificationExpiresAt,
    passwordResetTokenHash,
    passwordResetExpiresAt,
    ...safe
  } = user;
  return safe;
}

function passwordIsValid(password) {
  return typeof password === 'string' && password.length >= 12
    && /[a-z]/.test(password) && /[A-Z]/.test(password)
    && /\d/.test(password) && /[^A-Za-z0-9]/.test(password);
}

function permissionsForRoles(roleNames, roles) {
  return [...new Set(roleNames.flatMap((name) => roles.find((role) => role.name === name)?.permissions || []))];
}

function registerUserRoutes({ app, users, roles, permissions, departments = [], departmentReferences = [], authMiddleware, requirePermission, logEvent, authRateLimit = (_req, _res, next) => next(), skipEmailVerification = false, onTokenIssued, userStore, accountMailSender = sendAccountMail, dataSubjectExporter, onBeforeUserDelete }) {
  const appBaseUrl = process.env.APP_BASE_URL || 'https://materialkompass.org';
  const saveUser = (user) => userStore?.saveUser(user) || Promise.resolve();
  const deleteStoredUser = (id) => userStore?.deleteUser(id) || Promise.resolve();
  const saveRole = (role) => userStore?.saveRole(role) || Promise.resolve();
  const deleteStoredRole = (id) => userStore?.deleteRole(id) || Promise.resolve();

  function nextId(prefix, entries) {
    let id;
    do id = `${prefix}-${crypto.randomUUID()}`; while (entries.some((entry) => entry.id === id));
    return id;
  }

  function findUser(identifier) {
    const key = normalize(identifier);
    return users.find((user) => normalize(user.email) === key || normalize(user.username) === key);
  }

  function roleNamesAreValid(names) {
    return Array.isArray(names) && names.length > 0 && names.every((name) => roles.some((role) => role.name === name));
  }

  function departmentIdsAreValid(ids) {
    return Array.isArray(ids)
      && ids.every((id) => departments.some((department) => department.id === id && department.active !== false));
  }

  function validateDepartmentAssignment(roleNames, departmentIds) {
    if (!departmentIdsAreValid(departmentIds)) return 'Mindestens ein Fachbereich ist ungültig oder deaktiviert.';
    if (roleNames.includes('Fachbereichsleiter') && departmentIds.length === 0) {
      return 'Fachbereichsleiter benötigen mindestens einen zugewiesenen Fachbereich.';
    }
    return null;
  }

  function isLastAdmin(user) {
    return user.roles?.includes('Admin')
      && users.filter((entry) => entry.active && entry.roles?.includes('Admin')).length <= 1;
  }

  async function issueVerification(user) {
    const token = crypto.randomBytes(32).toString('hex');
    user.verificationTokenHash = tokenHash(token);
    user.verificationExpiresAt = new Date(Date.now() + VERIFY_TTL).toISOString();
    const url = `${appBaseUrl}/#/verify-email?token=${token}`;
    onTokenIssued?.({ type: 'verification', userId: user.id, token });
    return accountMailSender({
      to: user.email,
      subject: 'E-Mail-Adresse für MaterialKompass bestätigen',
      text: `Bitte bestätigen Sie Ihre E-Mail-Adresse innerhalb von 24 Stunden:\n\n${url}`,
    }).catch((error) => console.error('Verifizierungs-E-Mail fehlgeschlagen:', error.message));
  }

  async function issuePasswordReset(user) {
    const token = crypto.randomBytes(32).toString('hex');
    user.passwordResetTokenHash = tokenHash(token);
    user.passwordResetExpiresAt = new Date(Date.now() + RESET_TTL).toISOString();
    const url = `${appBaseUrl}/#/password-reset?token=${token}`;
    onTokenIssued?.({ type: 'password-reset', userId: user.id, token });
    return accountMailSender({
      to: user.email,
      subject: 'MaterialKompass-Passwort zurücksetzen',
      text: `Über diesen Link können Sie innerhalb einer Stunde ein neues Passwort setzen:\n\n${url}`,
    }).catch((error) => console.error('Passwort-E-Mail fehlgeschlagen:', error.message));
  }

  async function applyRetentionPolicy() {
    const now = Date.now();
    for (let index = users.length - 1; index >= 0; index -= 1) {
      const user = users[index];
      const reference = new Date(user.lastLoginAt || user.createdAt);
      if (!Number.isFinite(reference.getTime())) continue;
      const deactivationDate = new Date(reference);
      deactivationDate.setUTCMonth(deactivationDate.getUTCMonth() + 24);
      const deletionDate = new Date(reference);
      deletionDate.setUTCMonth(deletionDate.getUTCMonth() + 36);
      if (now >= deletionDate.getTime() && user.roles?.includes('Admin') && isLastAdmin(user)) continue;
      if (now >= deletionDate.getTime()) {
        logEvent('retention_delete', 'User', { id: user.id }, 'system');
        users.splice(index, 1);
        await deleteStoredUser(user.id);
      } else if (now >= deactivationDate.getTime() && user.active) {
        user.active = false;
        user.deactivatedAt = new Date().toISOString();
        user.deactivationReason = 'inactivity';
        user.scheduledDeletionAt = deletionDate.toISOString();
        logEvent('retention_deactivate', 'User', { id: user.id }, 'system');
        await saveUser(user);
      }
    }
  }

  app.locals.applyUserRetentionPolicy = applyRetentionPolicy;

  app.get('/api/departments', authMiddleware, (_req, res) => res.json(departments));

  app.post('/api/departments', authMiddleware, requirePermission('users.write'), (req, res) => {
    const name = String(req.body.name || '').trim();
    const code = String(req.body.code || '').trim().toUpperCase();
    if (!name || !code) return res.status(400).json({ error: 'Name und Kürzel sind erforderlich.' });
    if (departments.some((entry) => normalize(entry.name) === normalize(name) || normalize(entry.code) === normalize(code))) {
      return res.status(409).json({ error: 'Name oder Kürzel ist bereits vergeben.' });
    }
    const department = { id: nextId('department', departments), name, code, active: req.body.active !== false };
    departments.push(department);
    logEvent('create', 'Department', { id: department.id }, req.user.username);
    return res.status(201).json(department);
  });

  app.put('/api/departments/:id', authMiddleware, requirePermission('users.write'), (req, res) => {
    const department = departments.find((entry) => entry.id === req.params.id);
    if (!department) return res.status(404).json({ error: 'Fachbereich nicht gefunden.' });
    const name = String(req.body.name ?? department.name).trim();
    const code = String(req.body.code ?? department.code).trim().toUpperCase();
    if (!name || !code) return res.status(400).json({ error: 'Name und Kürzel sind erforderlich.' });
    if (departments.some((entry) => entry.id !== department.id
      && (normalize(entry.name) === normalize(name) || normalize(entry.code) === normalize(code)))) {
      return res.status(409).json({ error: 'Name oder Kürzel ist bereits vergeben.' });
    }
    Object.assign(department, { name, code, active: req.body.active ?? department.active });
    departmentReferences
      .filter((entry) => entry.departmentId === department.id)
      .forEach((entry) => { entry.department = name; });
    logEvent('update', 'Department', { id: department.id }, req.user.username);
    return res.json(department);
  });

  app.delete('/api/departments/:id', authMiddleware, requirePermission('users.write'), (req, res) => {
    const index = departments.findIndex((entry) => entry.id === req.params.id);
    if (index < 0) return res.status(404).json({ error: 'Fachbereich nicht gefunden.' });
    if (users.some((user) => user.departmentIds?.includes(req.params.id))
      || departmentReferences.some((entry) => entry.departmentId === req.params.id)) {
      return res.status(409).json({ error: 'Zugewiesene oder verwendete Fachbereiche können nicht gelöscht werden. Deaktivieren Sie den Fachbereich stattdessen.' });
    }
    const [department] = departments.splice(index, 1);
    logEvent('delete', 'Department', { id: department.id }, req.user.username);
    return res.status(204).end();
  });

  app.get('/api/roles', authMiddleware, requirePermission('roles.read'), (_req, res) => res.json(roles));

  app.post('/api/roles', authMiddleware, requirePermission('users.write'), async (req, res) => {
    const name = String(req.body.name || '').trim();
    const selectedPermissions = req.body.permissions;
    if (!name || roles.some((role) => normalize(role.name) === normalize(name))) {
      return res.status(409).json({ error: 'Rollenname fehlt oder ist bereits vergeben.' });
    }
    if (!Array.isArray(selectedPermissions) || selectedPermissions.some((item) => !permissions.includes(item))) {
      return res.status(400).json({ error: 'Ungültige Berechtigungen.' });
    }
    const role = { id: nextId('role', roles), name, permissions: [...new Set(selectedPermissions)] };
    roles.push(role);
    await saveRole(role);
    logEvent('create', 'Role', { id: role.id }, req.user.username);
    return res.status(201).json(role);
  });

  app.put('/api/roles/:id', authMiddleware, requirePermission('users.write'), async (req, res) => {
    const role = roles.find((entry) => entry.id === req.params.id);
    if (!role) return res.status(404).json({ error: 'Rolle nicht gefunden.' });
    if (role.name === 'Admin' && req.body.name && req.body.name !== 'Admin') {
      return res.status(400).json({ error: 'Die Systemrolle Admin kann nicht umbenannt werden.' });
    }
    const name = String(req.body.name ?? role.name).trim();
    const selectedPermissions = req.body.permissions ?? role.permissions;
    if (!name || roles.some((entry) => entry.id !== role.id && normalize(entry.name) === normalize(name))) {
      return res.status(409).json({ error: 'Rollenname ist bereits vergeben.' });
    }
    if (!Array.isArray(selectedPermissions) || selectedPermissions.some((item) => !permissions.includes(item))) {
      return res.status(400).json({ error: 'Ungültige Berechtigungen.' });
    }
    const oldName = role.name;
    role.name = name;
    role.permissions = [...new Set(selectedPermissions)];
    users.forEach((user) => {
      user.roles = user.roles.map((entry) => entry === oldName ? name : entry);
      user.permissions = permissionsForRoles(user.roles, roles);
    });
    await saveRole(role);
    await Promise.all(users.map(saveUser));
    logEvent('update', 'Role', { id: role.id }, req.user.username);
    return res.json(role);
  });

  app.delete('/api/roles/:id', authMiddleware, requirePermission('users.write'), async (req, res) => {
    const index = roles.findIndex((entry) => entry.id === req.params.id);
    if (index < 0) return res.status(404).json({ error: 'Rolle nicht gefunden.' });
    const role = roles[index];
    if (role.name === 'Admin' || users.some((user) => user.roles.includes(role.name))) {
      return res.status(409).json({ error: 'Systemrollen oder verwendete Rollen können nicht gelöscht werden.' });
    }
    roles.splice(index, 1);
    await deleteStoredRole(role.id);
    logEvent('delete', 'Role', { id: role.id }, req.user.username);
    return res.status(204).end();
  });

  app.get('/api/users', authMiddleware, requirePermission('users.read'), async (req, res) => {
    await applyRetentionPolicy();
    const search = normalize(req.query.search);
    const result = search ? users.filter((user) => [user.name, user.username, user.email]
      .some((value) => normalize(value).includes(search))) : users;
    return res.json(result.map(publicUser));
  });

  app.post('/api/users', authMiddleware, requirePermission('users.write'), async (req, res) => {
    const { name, username, email, password, roles: roleNames = ['Nutzer'], departmentIds = [] } = req.body;
    if (!String(username || '').trim() || !normalize(email).includes('@')) {
      return res.status(400).json({ error: 'Nutzername und gültige E-Mail-Adresse sind erforderlich.' });
    }
    if (findUser(username) || findUser(email)) return res.status(409).json({ error: 'Nutzername oder E-Mail-Adresse ist bereits vergeben.' });
    const hasStartPassword = typeof password === 'string' && password.length > 0;
    if (hasStartPassword && !passwordIsValid(password)) return res.status(400).json({ error: 'Das Passwort muss mindestens 12 Zeichen sowie Groß-/Kleinbuchstaben, Zahl und Sonderzeichen enthalten.' });
    if (!roleNamesAreValid(roleNames)) return res.status(400).json({ error: 'Mindestens eine gültige Rolle ist erforderlich.' });
    const departmentError = validateDepartmentAssignment(roleNames, departmentIds);
    if (departmentError) return res.status(400).json({ error: departmentError });
    const user = {
      id: nextId('user', users), name: String(name || '').trim(), username: String(username).trim(),
      email: normalize(email), passwordHash: await bcrypt.hash(hasStartPassword ? password : crypto.randomBytes(32).toString('hex'), 12), roles: roleNames,
      departmentIds: [...new Set(departmentIds)],
      permissions: permissionsForRoles(roleNames, roles), active: req.body.active !== false,
      emailVerifiedAt: skipEmailVerification ? new Date().toISOString() : null, failedLoginAttempts: 0, lockedUntil: null,
      createdAt: new Date().toISOString(), lastLoginAt: null,
    };
    users.push(user);
    if (!skipEmailVerification) await issueVerification(user);
    if (!hasStartPassword) await issuePasswordReset(user);
    await saveUser(user);
    logEvent('create', 'User', { id: user.id }, req.user.username);
    return res.status(201).json(publicUser(user));
  });

  app.put('/api/users/:id', authMiddleware, requirePermission('users.write'), async (req, res) => {
    const user = users.find((entry) => entry.id === req.params.id);
    if (!user) return res.status(404).json({ error: 'Nutzer nicht gefunden.' });
    const email = normalize(req.body.email ?? user.email);
    const username = String(req.body.username ?? user.username).trim();
    const roleNames = req.body.roles ?? user.roles;
    const departmentIds = req.body.departmentIds ?? user.departmentIds ?? [];
    if (!username || !email.includes('@')) return res.status(400).json({ error: 'Ungültige Nutzerdaten.' });
    if (users.some((entry) => entry.id !== user.id && (normalize(entry.email) === email || normalize(entry.username) === normalize(username)))) {
      return res.status(409).json({ error: 'Nutzername oder E-Mail-Adresse ist bereits vergeben.' });
    }
    if (!roleNamesAreValid(roleNames)) return res.status(400).json({ error: 'Ungültige Rolle.' });
    const departmentError = validateDepartmentAssignment(roleNames, departmentIds);
    if (departmentError) return res.status(400).json({ error: departmentError });
    const nextActive = req.body.active ?? user.active;
    if ((!nextActive || !roleNames.includes('Admin')) && isLastAdmin(user)) return res.status(409).json({ error: 'Der letzte aktive Admin kann nicht deaktiviert oder herabgestuft werden.' });
    if (req.body.password && !passwordIsValid(req.body.password)) return res.status(400).json({ error: 'Das neue Passwort erfüllt die Sicherheitsanforderungen nicht.' });
    const emailChanged = email !== normalize(user.email);
    Object.assign(user, { name: String(req.body.name ?? user.name ?? '').trim(), username, email, roles: roleNames, departmentIds: [...new Set(departmentIds)], active: nextActive });
    user.permissions = permissionsForRoles(roleNames, roles);
    if (req.body.password) {
      user.passwordHash = await bcrypt.hash(req.body.password, 12);
    }
    if (emailChanged) { user.emailVerifiedAt = null; await issueVerification(user); }
    if (nextActive) { user.deactivatedAt = null; user.deactivationReason = null; user.scheduledDeletionAt = null; }
    await saveUser(user);
    logEvent('update', 'User', { id: user.id }, req.user.username);
    return res.json(publicUser(user));
  });

  app.post('/api/users/:id/password-reset', authMiddleware, requirePermission('users.write'), async (req, res) => {
    const user = users.find((entry) => entry.id === req.params.id);
    if (user) { await issuePasswordReset(user); await saveUser(user); logEvent('password_reset_requested', 'User', { id: user.id }, req.user.username); }
    return res.status(202).json({ message: 'Wenn das Konto existiert, wurde eine E-Mail versendet.' });
  });

  app.delete('/api/users/:id', authMiddleware, requirePermission('users.write'), async (req, res) => {
    const index = users.findIndex((entry) => entry.id === req.params.id);
    if (index < 0) return res.status(404).json({ error: 'Nutzer nicht gefunden.' });
    if (isLastAdmin(users[index])) return res.status(409).json({ error: 'Der letzte aktive Admin kann nicht gelöscht werden.' });
    const [deleted] = users.splice(index, 1);
    await onBeforeUserDelete?.(deleted);
    await deleteStoredUser(deleted.id);
    logEvent('delete', 'User', { id: deleted.id }, req.user.username);
    return res.status(204).end();
  });

  app.put('/api/users/me', authMiddleware, async (req, res) => {
    const user = req.user;
    const valid = await bcrypt.compare(req.body.currentPassword || '', user.passwordHash);
    if (!valid) return res.status(403).json({ error: 'Das aktuelle Passwort ist nicht korrekt.' });
    if (req.body.email) {
      const email = normalize(req.body.email);
      if (!email.includes('@') || users.some((entry) => entry.id !== user.id && normalize(entry.email) === email)) return res.status(409).json({ error: 'Ungültige oder bereits verwendete E-Mail-Adresse.' });
      if (email !== normalize(user.email)) { user.email = email; user.emailVerifiedAt = null; await issueVerification(user); }
    }
    if (req.body.password) {
      if (!passwordIsValid(req.body.password)) return res.status(400).json({ error: 'Das neue Passwort erfüllt die Sicherheitsanforderungen nicht.' });
      user.passwordHash = await bcrypt.hash(req.body.password, 12);
    }
    await saveUser(user);
    logEvent('self_update', 'User', { id: user.id }, user.username);
    return res.json(publicUser(user));
  });

  app.get('/api/users/me/export', authMiddleware, (req, res) => {
    const payload = dataSubjectExporter
      ? dataSubjectExporter(req.user)
      : { generatedAt: new Date().toISOString(), account: publicUser(req.user), relatedData: {} };
    logEvent('self_export', 'User', { id: req.user.id }, req.user.username);
    res.set('Content-Disposition', 'attachment; filename="materialkompass-datenkopie.json"');
    return res.json(payload);
  });

  app.delete('/api/users/me', authMiddleware, async (req, res) => {
    if (!await bcrypt.compare(req.body.password || '', req.user.passwordHash)) return res.status(403).json({ error: 'Das Passwort ist nicht korrekt.' });
    if (isLastAdmin(req.user)) return res.status(409).json({ error: 'Der letzte aktive Admin kann sein Konto nicht löschen.' });
    await onBeforeUserDelete?.(req.user);
    users.splice(users.findIndex((entry) => entry.id === req.user.id), 1);
    await deleteStoredUser(req.user.id);
    logEvent('self_delete', 'User', { id: req.user.id }, req.user.username);
    return res.status(204).end();
  });

  app.post('/api/auth/password-reset', authRateLimit, async (req, res) => {
    const user = findUser(req.body.email || req.body.identifier);
    if (user?.active) {
      await issuePasswordReset(user);
      await saveUser(user);
      logEvent('password_reset_requested', 'User', { id: user.id }, user.username);
    }
    return res.status(202).json({ message: 'Wenn das Konto existiert, wurde eine E-Mail versendet.' });
  });

  app.post('/api/auth/password-reset/confirm', authRateLimit, async (req, res) => {
    const hash = tokenHash(req.body.token || '');
    const user = users.find((entry) => entry.passwordResetTokenHash === hash);
    if (!user || new Date(user.passwordResetExpiresAt).getTime() < Date.now()) {
      return res.status(400).json({ error: 'Der Link ist ungültig oder abgelaufen.' });
    }
    if (!passwordIsValid(req.body.password)) return res.status(400).json({ error: 'Das neue Passwort erfüllt die Sicherheitsanforderungen nicht.' });
    user.passwordHash = await bcrypt.hash(req.body.password, 12);
    user.passwordResetTokenHash = null;
    user.passwordResetExpiresAt = null;
    user.failedLoginAttempts = 0;
    user.lockedUntil = null;
    await saveUser(user);
    logEvent('password_reset_completed', 'User', { id: user.id }, user.username);
    return res.json({ message: 'Das Passwort wurde geändert.' });
  });

  app.get('/api/auth/verify-email', authRateLimit, async (req, res) => {
    const hash = tokenHash(req.query.token || '');
    const user = users.find((entry) => entry.verificationTokenHash === hash);
    if (!user || new Date(user.verificationExpiresAt).getTime() < Date.now()) {
      return res.status(400).json({ error: 'Der Link ist ungültig oder abgelaufen.' });
    }
    user.emailVerifiedAt = new Date().toISOString();
    user.verificationTokenHash = null;
    user.verificationExpiresAt = null;
    await saveUser(user);
    logEvent('email_verified', 'User', { id: user.id }, user.username);
    return res.json({ message: 'Die E-Mail-Adresse wurde bestätigt.' });
  });

  app.post('/api/auth/verification/resend', authRateLimit, async (req, res) => {
    const user = findUser(req.body.email || req.body.identifier);
    if (user?.active && !user.emailVerifiedAt) { await issueVerification(user); await saveUser(user); }
    return res.status(202).json({ message: 'Wenn eine Bestätigung erforderlich ist, wurde eine E-Mail versendet.' });
  });

  return { findUser, publicUser, issuePasswordReset, applyRetentionPolicy };
}

module.exports = { registerUserRoutes, publicUser, passwordIsValid, tokenHash };
