const LOGIN_ACCESS_MODES = Object.freeze({
  ALL_CLIENTS: 'all_clients',
  SERVICE_DEVICES: 'service_devices',
  SELECTED_SERVICE_DEVICES: 'selected_service_devices',
});

const VALID_LOGIN_ACCESS_MODES = new Set(Object.values(LOGIN_ACCESS_MODES));
const MAX_ALLOWED_SERVICE_DEVICES = 250;

function loginAccessPolicy(user) {
  const mode = VALID_LOGIN_ACCESS_MODES.has(user?.loginAccessMode)
    ? user.loginAccessMode
    : LOGIN_ACCESS_MODES.ALL_CLIENTS;
  const allowedServiceDeviceIds = [...new Set(
    (Array.isArray(user?.allowedServiceDeviceIds) ? user.allowedServiceDeviceIds : [])
      .map((value) => String(value || '').trim())
      .filter(Boolean),
  )].sort();
  return { mode, allowedServiceDeviceIds };
}

function loginAccessAllowed(user, deviceId = null) {
  const policy = loginAccessPolicy(user);
  if (policy.mode === LOGIN_ACCESS_MODES.ALL_CLIENTS) return true;
  if (!deviceId) return false;
  if (policy.mode === LOGIN_ACCESS_MODES.SERVICE_DEVICES) return true;
  return policy.allowedServiceDeviceIds.includes(String(deviceId));
}

function validateLoginAccessPolicy({ mode, allowedServiceDeviceIds }, {
  devices = [], organizationId = null,
} = {}) {
  if (!VALID_LOGIN_ACCESS_MODES.has(mode)) {
    return { error: 'Ungültige Anmelderichtlinie.' };
  }
  if (!Array.isArray(allowedServiceDeviceIds)) {
    return { error: 'Die erlaubten Dienstgeräte müssen als Liste angegeben werden.' };
  }
  const ids = [...new Set(allowedServiceDeviceIds.map((value) => String(value || '').trim()))];
  if (ids.some((id) => !id) || ids.length > MAX_ALLOWED_SERVICE_DEVICES) {
    return { error: `Es dürfen höchstens ${MAX_ALLOWED_SERVICE_DEVICES} Dienstgeräte ausgewählt werden.` };
  }
  if (mode !== LOGIN_ACCESS_MODES.SELECTED_SERVICE_DEVICES) {
    return { mode, allowedServiceDeviceIds: [] };
  }
  if (ids.length === 0) {
    return { error: 'Für diese Anmelderichtlinie muss mindestens ein Dienstgerät ausgewählt werden.' };
  }
  const availableIds = new Set(devices
    .filter((device) => !organizationId || device.organizationId === organizationId)
    .map((device) => device.id));
  if (ids.some((id) => !availableIds.has(id))) {
    return { error: 'Mindestens ein ausgewähltes Dienstgerät ist nicht verfügbar.' };
  }
  return { mode, allowedServiceDeviceIds: ids.sort() };
}

module.exports = {
  LOGIN_ACCESS_MODES,
  MAX_ALLOWED_SERVICE_DEVICES,
  loginAccessAllowed,
  loginAccessPolicy,
  validateLoginAccessPolicy,
};
