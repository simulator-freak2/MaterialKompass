const DUMMY = '[DUMMY – vor Produktivbetrieb ersetzen]';

function value(env, name) {
  return String(env[name] || DUMMY).trim();
}

function legalInformation(env = process.env) {
  const controller = {
    name: value(env, 'LEGAL_CONTROLLER_NAME'),
    legalForm: value(env, 'LEGAL_LEGAL_FORM'),
    representedBy: value(env, 'LEGAL_REPRESENTED_BY'),
    street: value(env, 'LEGAL_STREET'),
    postalCode: value(env, 'LEGAL_POSTAL_CODE'),
    city: value(env, 'LEGAL_CITY'),
    country: value(env, 'LEGAL_COUNTRY'),
    email: value(env, 'LEGAL_EMAIL'),
    phone: value(env, 'LEGAL_PHONE'),
    register: value(env, 'LEGAL_REGISTER'),
    registerNumber: value(env, 'LEGAL_REGISTER_NUMBER'),
    vatId: value(env, 'LEGAL_VAT_ID'),
  };
  const retention = {
    auditDays: Number(env.RETENTION_AUDIT_DAYS || 1095),
    exportDays: Number(env.RETENTION_EXPORT_LOG_DAYS || 365),
    notificationDays: Number(env.RETENTION_NOTIFICATION_DAYS || 365),
    expiredQrDays: Number(env.RETENTION_EXPIRED_QR_DAYS || 30),
  };
  const additionalFields = [
    'LEGAL_DPO_NAME', 'LEGAL_DPO_EMAIL', 'LEGAL_DPO_ADDRESS',
    'LEGAL_SUPERVISORY_AUTHORITY', 'LEGAL_SUPERVISORY_ADDRESS',
    'LEGAL_SUPERVISORY_WEBSITE', 'LEGAL_ACCOUNT_BASIS',
    'LEGAL_OPERATIONS_BASIS', 'LEGAL_LEGITIMATE_INTERESTS',
  ];
  const hasDummies = Object.values(controller).some((entry) => entry.includes('[DUMMY'))
    || additionalFields.some((name) => value(env, name).includes('[DUMMY'));
  return {
    version: '2026-07-28',
    hasDummies,
    provider: controller,
    privacy: {
      controller,
      dataProtectionOfficer: {
        name: value(env, 'LEGAL_DPO_NAME'),
        email: value(env, 'LEGAL_DPO_EMAIL'),
        address: value(env, 'LEGAL_DPO_ADDRESS'),
      },
      supervisoryAuthority: {
        name: value(env, 'LEGAL_SUPERVISORY_AUTHORITY'),
        address: value(env, 'LEGAL_SUPERVISORY_ADDRESS'),
        website: value(env, 'LEGAL_SUPERVISORY_WEBSITE'),
      },
      purposes: [
        'Benutzerverwaltung, Authentifizierung und Berechtigungssteuerung',
        'Inventar-, Kleiderkammer-, Mängel- und Beschaffungsverwaltung',
        'Nachvollziehbarkeit sicherheits- und bestandsrelevanter Änderungen',
        'Bereitstellung, Absicherung und Fehleranalyse des Dienstes',
      ],
      legalBases: [
        `Konten und Authentifizierung: ${value(env, 'LEGAL_ACCOUNT_BASIS')}`,
        `Fachvorgänge und Nachweise: ${value(env, 'LEGAL_OPERATIONS_BASIS')}`,
        `Berechtigte Interessen, falls Art. 6 Abs. 1 lit. f DSGVO genutzt wird: ${value(env, 'LEGAL_LEGITIMATE_INTERESTS')}`,
      ],
      recipients: [
        'Autorisierte Beschäftigte und Funktionsträger des Betreibers',
        'Beauftragte Hosting-, E-Mail- und IT-Dienstleister auf Grundlage eines Auftragsverarbeitungsvertrags',
        'Behörden oder sonstige Stellen, soweit eine gesetzliche Verpflichtung besteht',
      ],
      transfers: 'Eine Übermittlung in Drittländer ist nicht vorgesehen. Abweichungen sind vor Produktivbetrieb zu dokumentieren.',
      retention: [
        'Aktive Kontodaten: für die Dauer der Nutzungsberechtigung',
        'Inaktive Konten: Deaktivierung nach 24 Monaten, Löschung nach 36 Monaten ohne Anmeldung',
        'Fach- und Auditdaten: nach dem dokumentierten Löschkonzept des Betreibers; gesetzliche Aufbewahrungspflichten gehen vor',
        'Verifizierungslinks: 24 Stunden; Passwort-Reset-Links: 1 Stunde; Anmeldetoken: 1 Stunde',
        `Auditdaten: ${retention.auditDays} Tage; Exportprotokolle: ${retention.exportDays} Tage`,
        `Benachrichtigungen: ${retention.notificationDays} Tage; abgelaufene QR-Anmeldedaten: weitere ${retention.expiredQrDays} Tage`,
      ],
      rights: [
        'Auskunft und Datenkopie (Art. 15 DSGVO)',
        'Berichtigung (Art. 16 DSGVO)',
        'Löschung (Art. 17 DSGVO)',
        'Einschränkung der Verarbeitung (Art. 18 DSGVO)',
        'Datenübertragbarkeit, soweit anwendbar (Art. 20 DSGVO)',
        'Widerspruch gegen Verarbeitungen auf Grundlage von Art. 6 Abs. 1 lit. e oder f DSGVO (Art. 21 DSGVO)',
        'Beschwerde bei einer Datenschutzaufsichtsbehörde (Art. 77 DSGVO)',
      ],
      requiredData: 'Pflichtangaben sind für Anmeldung, Berechtigungsprüfung und die jeweiligen Fachvorgänge erforderlich. Ohne sie kann der Dienst ganz oder teilweise nicht genutzt werden.',
      automatedDecisions: 'Es findet keine automatisierte Entscheidungsfindung einschließlich Profiling im Sinne von Art. 22 DSGVO statt.',
      localStorage: 'Die Anwendung verwendet ausschließlich technisch erforderliche lokale Einstellungen, etwa für konfigurierte Etikettendrucker. Es werden keine Analyse-, Marketing- oder Tracking-Technologien eingesetzt.',
    },
  };
}

const requiredProductionFields = [
  'LEGAL_CONTROLLER_NAME', 'LEGAL_LEGAL_FORM', 'LEGAL_REPRESENTED_BY',
  'LEGAL_STREET', 'LEGAL_POSTAL_CODE', 'LEGAL_CITY', 'LEGAL_COUNTRY',
  'LEGAL_EMAIL', 'LEGAL_PHONE', 'LEGAL_SUPERVISORY_AUTHORITY',
  'LEGAL_SUPERVISORY_WEBSITE', 'LEGAL_ACCOUNT_BASIS',
  'LEGAL_OPERATIONS_BASIS', 'LEGAL_LEGITIMATE_INTERESTS',
];

function validateLegalConfig(env = process.env) {
  if (env.NODE_ENV !== 'production') return;
  const missing = requiredProductionFields.filter((name) => {
    const entry = String(env[name] || '').trim();
    return !entry || entry.includes('[DUMMY') || /^replace-/i.test(entry);
  });
  if (missing.length) {
    throw new Error(`Rechtliche Pflichtangaben fehlen: ${missing.join(', ')}.`);
  }
}

module.exports = { DUMMY, legalInformation, validateLegalConfig };
