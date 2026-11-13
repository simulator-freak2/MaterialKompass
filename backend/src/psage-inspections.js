'use strict';

const {
  AGE_LIMITS,
  BUOYANCY_VALUES,
  DEFAULT_INTERVAL_MONTHS,
  PSAGE_CHECKLIST_VERSION,
  RELEASE_TYPES,
  VEST_TYPES,
  applicableChecklist,
  publicChecklists,
} = require('./psage-checklists');
const { generatePsageInspectionPdf } = require('./psage-inspection-pdf');

const RATINGS = new Set(['na', 'ok', 'ko']);
const DUE_WARNING_DAYS = 30;
const MAX_REMARK_LENGTH = 500;
const MAX_TEXT_LENGTH = 5000;

const DEFAULT_SETTINGS = Object.freeze({
  visualCheckEnabled: false,
  pdfEnabled: false,
  pdfArchiveRequired: false,
});

function normalizePsageSettings(value) {
  const source = value && typeof value === 'object' ? value : {};
  const pdfEnabled = source.pdfEnabled === true;
  return {
    visualCheckEnabled: source.visualCheckEnabled === true,
    pdfEnabled,
    // Eine Ablagepflicht setzt den PDF-Nachweis voraus.
    pdfArchiveRequired: pdfEnabled && source.pdfArchiveRequired === true,
  };
}

function validDate(value) {
  const raw = String(value || '').trim().slice(0, 10);
  if (!/^\d{4}-\d{2}-\d{2}$/.test(raw)) return null;
  const parsed = new Date(`${raw}T00:00:00.000Z`);
  return Number.isFinite(parsed.getTime()) && parsed.toISOString().slice(0, 10) === raw ? raw : null;
}

/**
 * Normalisiert das Herstellungsdatum. Monatsangaben (JJJJ-MM) und ein reines
 * Baujahr werden auf den ersten Tag gesetzt; das ist die vorsichtigere Annahme
 * für die Altersgrenzen.
 */
function normalizeManufactureDate(value) {
  const raw = String(value || '').trim();
  if (!raw) return null;
  if (/^\d{4}-\d{2}$/.test(raw)) return validDate(`${raw}-01`);
  if (/^\d{4}$/.test(raw)) return validDate(`${raw}-01-01`);
  return validDate(raw);
}

function manufactureDateOf(item) {
  return normalizeManufactureDate(item?.manufactureDate)
    || normalizeManufactureDate(item?.manufacturingYear);
}

function addYears(date, years) {
  const [year, month, day] = date.split('-').map(Number);
  const target = new Date(Date.UTC(year + years, month - 1, 1));
  const lastDay = new Date(Date.UTC(target.getUTCFullYear(), target.getUTCMonth() + 1, 0)).getUTCDate();
  target.setUTCDate(Math.min(day, lastDay));
  return target.toISOString().slice(0, 10);
}

function today(now = new Date()) {
  return new Date(now).toISOString().slice(0, 10);
}

function daysBetween(from, to) {
  return Math.round((Date.parse(`${to}T00:00:00Z`) - Date.parse(`${from}T00:00:00Z`)) / 86_400_000);
}

function vestDetails(item, category) {
  const vestType = VEST_TYPES[category?.psageVestType] ? category.psageVestType : null;
  if (!vestType) return null;
  return {
    vestType,
    releaseType: vestType === 'lifejacket'
      ? (RELEASE_TYPES[item?.psageReleaseType] ? item.psageReleaseType : 'automatic')
      : null,
    buoyancyNewton: BUOYANCY_VALUES.includes(Number(item?.psageBuoyancyNewton))
      ? Number(item.psageBuoyancyNewton) : null,
    swiftwaterRescue: vestType === 'buoyancy-aid' && item?.psageSwiftwaterRescue === true,
    manufactureDate: manufactureDateOf(item),
    serialNumber: String(item?.serialNumber || '').trim(),
    manufacturer: String(item?.manufacturer || '').trim(),
  };
}

function sortInspections(entries) {
  return entries.slice().sort((left, right) =>
    String(left.inspectionDate).localeCompare(String(right.inspectionDate))
    || String(left.createdAt).localeCompare(String(right.createdAt)));
}

/**
 * Berechnet (ohne zu speichern) die Einsatzfreigabe einer PSAgE-Weste.
 * Die API sperrt die Ausgabe, solange mindestens ein Grund vorliegt.
 */
function assessPsageSafety({ item, category, inspections = [], now = new Date() }) {
  const vest = vestDetails(item, category);
  if (!vest) return null;
  const reasons = [];
  const warnings = [];
  const current = today(now);
  const limits = AGE_LIMITS[vest.vestType];
  if (!vest.manufactureDate) {
    reasons.push('Das Herstellungsdatum ist nicht hinterlegt.');
  } else {
    const blockDate = addYears(vest.manufactureDate, limits.blockYears);
    if (blockDate <= current) {
      reasons.push(`Die Weste ist älter als ${limits.blockYears} Jahre und muss ausgesondert werden.`);
    } else if (limits.biennialYears && addYears(vest.manufactureDate, limits.biennialYears) <= current) {
      warnings.push(`Die Weste ist älter als ${limits.biennialYears} Jahre: jährliche Prüfung, Aussonderung spätestens am ${blockDate}.`);
    }
  }
  const relevant = sortInspections(inspections.filter((entry) => entry.psageChecklist === true));
  const expert = relevant.filter((entry) => entry.kind === 'expert');
  const latestExpert = expert.at(-1);
  if (!latestExpert) {
    reasons.push('Eine Prüfung durch einen Sachkundigen ist nicht nachgewiesen.');
  } else if (latestExpert.ready !== true) {
    reasons.push(`Die letzte Sachkundigenprüfung vom ${latestExpert.inspectionDate} ergab: nicht einsatzbereit.`);
  }
  const nextDate = validDate(item?.nextInspectionDate);
  if (latestExpert && !nextDate) {
    reasons.push('Der nächste Prüftermin fehlt.');
  } else if (nextDate && nextDate < current) {
    reasons.push(`Der Prüftermin ${nextDate} ist überschritten.`);
  } else if (nextDate && daysBetween(current, nextDate) <= DUE_WARNING_DAYS) {
    warnings.push(`Die nächste Prüfung ist am ${nextDate} fällig.`);
  }
  const latestVisual = relevant.filter((entry) => entry.kind === 'visual').at(-1);
  if (latestVisual && latestVisual.ready !== true
      && (!latestExpert || `${latestVisual.inspectionDate}${latestVisual.createdAt}` > `${latestExpert.inspectionDate}${latestExpert.createdAt}`)) {
    reasons.push(`Die Sichtprüfung vom ${latestVisual.inspectionDate} ergab: nicht einsatzbereit.`);
  }
  return {
    ...vest,
    blocked: reasons.length > 0,
    reasons,
    warnings,
    lastExpertInspectionDate: latestExpert?.inspectionDate || null,
    lastVisualInspectionDate: latestVisual?.inspectionDate || null,
  };
}

function number(value) {
  if (value === null || value === undefined || String(value).trim() === '') return null;
  const parsed = Number(String(value).replace(',', '.'));
  return Number.isFinite(parsed) && parsed >= 0 && parsed < 100_000 ? Math.round(parsed * 100) / 100 : NaN;
}

function evaluateMeasurements(raw, ratingsById) {
  const source = raw && typeof raw === 'object' ? raw : {};
  const measurement = {
    gasType: String(source.gasType || '').trim().slice(0, 32),
    grossMass: number(source.grossMass),
    grossTolerance: number(source.grossTolerance),
    gasMass: number(source.gasMass),
    gasTolerance: number(source.gasTolerance),
    actualMass: number(source.actualMass),
  };
  if (Object.values(measurement).some((value) => Number.isNaN(value))) {
    return { error: 'Die Massenangaben der Druckgasflasche müssen Zahlen sein.' };
  }
  const weighed = ratingsById.get('lj-2.12')?.rating !== 'na';
  if (!weighed) return { measurement: { ...measurement, expectedMass: null, expectedTolerance: null, withinTolerance: null } };
  if (!measurement.gasType || [measurement.grossMass, measurement.gasMass, measurement.actualMass].some((value) => value === null)) {
    return { error: 'Für die Druckgasflasche sind Gas, Mindest-Bruttomasse, Masse des Gasinhalts und Ist-Masse anzugeben.' };
  }
  const expectedMass = Math.round((measurement.grossMass + measurement.gasMass) * 100) / 100;
  const expectedTolerance = Math.round(((measurement.grossTolerance || 0) + (measurement.gasTolerance || 0)) * 100) / 100;
  const withinTolerance = Math.abs(measurement.actualMass - expectedMass) <= expectedTolerance + 1e-9;
  return { measurement: { ...measurement, expectedMass, expectedTolerance, withinTolerance } };
}

/**
 * Prüft die eingereichte Checkliste und leitet das Ergebnis serverseitig ab.
 * Ein Client kann eine Weste daher nicht trotz KO-Position freigeben.
 */
function evaluateInspection({ body, kind, vest, inspectionDate }) {
  const checklist = applicableChecklist(kind, vest.vestType, vest);
  const submitted = body.ratings && typeof body.ratings === 'object' && !Array.isArray(body.ratings)
    ? body.ratings : {};
  const entries = [];
  const missing = [];
  for (const section of checklist.sections) {
    for (const entry of section.items) {
      const raw = submitted[entry.id];
      const rating = String((raw && typeof raw === 'object' ? raw.rating : raw) || '').trim().toLowerCase();
      const remark = String((raw && typeof raw === 'object' ? raw.remark : '') || '').trim().slice(0, MAX_REMARK_LENGTH);
      if (!RATINGS.has(rating)) {
        missing.push(entry.position);
        continue;
      }
      entries.push({
        id: entry.id, sectionId: section.id, sectionTitle: section.title,
        position: entry.position, label: entry.label, rating, remark,
      });
    }
  }
  if (missing.length) {
    return { error: `Bitte alle Positionen mit N/A, OK oder KO bewerten (offen: ${[...new Set(missing)].join(', ')}).` };
  }
  const ratingsById = new Map(entries.map((entry) => [entry.id, entry]));
  const autoFindings = [];
  let measurement = null;
  if (kind === 'expert' && vest.vestType === 'lifejacket') {
    const evaluated = evaluateMeasurements(body.measurements, ratingsById);
    if (evaluated.error) return { error: evaluated.error };
    measurement = evaluated.measurement;
    if (measurement.withinTolerance === false) {
      autoFindings.push(`Füllstand der Druckgasflasche außerhalb der Toleranz (Soll ${measurement.expectedMass} ± ${measurement.expectedTolerance} g, Ist ${measurement.actualMass} g).`);
    }
  }
  let serviceTagDueDate = null;
  if (vest.vestType === 'lifejacket' && body.serviceTagDueDate) {
    serviceTagDueDate = validDate(body.serviceTagDueDate);
    if (!serviceTagDueDate) return { error: 'Das Datum der Prüfplakette ist ungültig.' };
    if (serviceTagDueDate < inspectionDate) autoFindings.push(`Die Prüfplakette ist seit ${serviceTagDueDate} abgelaufen.`);
  }
  if (vest.manufactureDate) {
    const limit = AGE_LIMITS[vest.vestType].blockYears;
    if (addYears(vest.manufactureDate, limit) <= inspectionDate) {
      autoFindings.push(`Die Weste ist zum Prüfdatum älter als ${limit} Jahre.`);
    }
  } else {
    autoFindings.push('Das Herstellungsdatum ist nicht hinterlegt.');
  }
  const koEntries = entries.filter((entry) => entry.rating === 'ko');
  koEntries.forEach((entry) => autoFindings.push(`KO in Pos. ${entry.position}: ${entry.label}${entry.remark ? ` (${entry.remark})` : ''}`));
  const ready = autoFindings.length === 0;
  const defectsText = String(body.defectsText || '').trim().slice(0, MAX_TEXT_LENGTH);
  const followUp = String(body.followUp || '').trim().slice(0, MAX_TEXT_LENGTH);
  if (!ready && !defectsText && !followUp) {
    return { error: 'Bitte die festgestellten Mängel und Anweisungen zum weiteren Vorgehen beschreiben.' };
  }
  return {
    checklist, entries, measurement, serviceTagDueDate, autoFindings, ready, defectsText, followUp,
  };
}

function registerPsageRoutes({
  app, authMiddleware, requirePermission, hasPermission, organizations, categories,
  clothingItems, clothingInspections, inspectionDocuments, defectManagement,
  logEvent, nextId, addMonths, categoryInspectionInterval,
}) {
  const organizationOf = (req) => organizations.find((entry) => entry.id === req.tenant?.organizationId);
  const settingsOf = (req) => normalizePsageSettings(organizationOf(req)?.psageSettings);
  const canManage = (req) => req.user.roles?.includes('Admin') && hasPermission(req.user, 'organizations.write');
  const isExpert = (user) => user.roles?.includes('Sachkundiger PSAgE') || user.roles?.includes('Admin');
  const categoryOf = (item) => categories.find((entry) => entry.id === item?.categoryId);
  const inspectionsOf = (item) => clothingInspections.filter((entry) => entry.clothingId === item.id);

  app.get('/api/psage/settings', authMiddleware, requirePermission('clothing.read'), (req, res) => {
    res.json({
      ...settingsOf(req),
      canManage: canManage(req),
      canInspect: hasPermission(req.user, 'clothing.inspect') && isExpert(req.user),
      checklists: publicChecklists(),
    });
  });

  app.put('/api/psage/settings', authMiddleware, requirePermission('organizations.write'), (req, res) => {
    if (!canManage(req)) {
      return res.status(403).json({ error: 'Nur Administratoren dürfen die PSAgE-Einstellungen ändern.' });
    }
    const organization = organizationOf(req);
    if (!organization) return res.status(404).json({ error: 'Organisation nicht gefunden.' });
    const previous = normalizePsageSettings(organization.psageSettings);
    const pick = (name) => (req.body[name] === undefined ? previous[name] : req.body[name] === true);
    organization.psageSettings = normalizePsageSettings({
      visualCheckEnabled: pick('visualCheckEnabled'),
      pdfEnabled: pick('pdfEnabled'),
      pdfArchiveRequired: pick('pdfArchiveRequired'),
    });
    logEvent('update', 'PsageSettings', organization.psageSettings, req.user.username);
    return res.json({ ...organization.psageSettings, canManage: true });
  });

  app.post('/api/clothing/:id/psage-inspections', authMiddleware, requirePermission('clothing.read'), async (req, res) => {
    const item = clothingItems.find((entry) => entry.id === req.params.id);
    if (!item) return res.status(404).json({ error: 'Kleidungsstück nicht gefunden.' });
    if (item.archived) return res.status(409).json({ error: 'Ausgesonderte Kleidung kann nicht geprüft werden.' });
    const vest = vestDetails(item, categoryOf(item));
    if (!vest) return res.status(409).json({ error: 'Für dieses Kleidungsstück ist kein PSAgE-Westentyp hinterlegt.' });
    const kind = String(req.body.kind || 'expert');
    const settings = settingsOf(req);
    if (kind === 'expert') {
      if (!hasPermission(req.user, 'clothing.inspect') || !isExpert(req.user)) {
        return res.status(403).json({ error: 'Diese Prüfung darf nur von Sachkundigen PSAgE durchgeführt werden.' });
      }
    } else if (kind === 'visual') {
      if (!settings.visualCheckEnabled) {
        return res.status(403).json({ error: 'Die Sichtprüfung durch Nutzer ist in dieser Organisation nicht aktiviert.' });
      }
    } else {
      return res.status(400).json({ error: 'Unbekannte Prüfart.' });
    }
    const inspectionDate = validDate(req.body.inspectionDate);
    if (!inspectionDate || inspectionDate > today()) {
      return res.status(400).json({ error: 'Ein gültiges Prüfdatum, das nicht in der Zukunft liegt, ist erforderlich.' });
    }
    const evaluation = evaluateInspection({ body: req.body, kind, vest, inspectionDate });
    if (evaluation.error) return res.status(400).json({ error: evaluation.error });

    let nextInspectionDate = null;
    let intervalMonths = null;
    if (kind === 'expert') {
      intervalMonths = categoryInspectionInterval(item.categoryId) || DEFAULT_INTERVAL_MONTHS[vest.vestType];
      const biennialYears = AGE_LIMITS[vest.vestType].biennialYears;
      if (biennialYears && vest.manufactureDate
          && addYears(vest.manufactureDate, biennialYears) <= inspectionDate) {
        intervalMonths = Math.min(intervalMonths, 12);
      }
      nextInspectionDate = addMonths(inspectionDate, intervalMonths);
      if (evaluation.serviceTagDueDate && evaluation.serviceTagDueDate < nextInspectionDate) {
        nextInspectionDate = evaluation.serviceTagDueDate;
      }
      if (vest.manufactureDate) {
        const blockDate = addYears(vest.manufactureDate, AGE_LIMITS[vest.vestType].blockYears);
        if (blockDate < nextInspectionDate) nextInspectionDate = blockDate;
      }
    }
    const inspection = {
      id: nextId('clothing-inspection', clothingInspections),
      clothingId: item.id,
      kind,
      psageChecklist: true,
      psageInspection: kind === 'expert',
      checklistVersion: PSAGE_CHECKLIST_VERSION,
      vestType: vest.vestType,
      vest,
      inspectionDate,
      inspector: req.user.name || req.user.email || req.user.username,
      inspectorEmail: req.user.email || '',
      result: evaluation.ready ? 'Bestanden' : 'Nicht bestanden',
      ready: evaluation.ready,
      checklist: evaluation.entries,
      measurements: evaluation.measurement,
      serviceTagDueDate: evaluation.serviceTagDueDate,
      autoFindings: evaluation.autoFindings,
      defectsText: evaluation.defectsText,
      followUp: evaluation.followUp,
      remarks: String(req.body.remarks || '').trim().slice(0, MAX_TEXT_LENGTH),
      notes: [evaluation.defectsText, evaluation.followUp].filter(Boolean).join('\n'),
      nextInspectionDate,
      intervalMonths,
      protocolDocumentId: null,
      createdAt: new Date().toISOString(),
    };

    // Das archivierte PDF wird vor jeder Zustandsänderung erzeugt, damit ein
    // Fehler keinen Prüfdatensatz ohne vorgeschriebenen Nachweis hinterlässt.
    let document = null;
    if (kind === 'expert' && settings.pdfArchiveRequired) {
      const buffer = await generatePsageInspectionPdf({
        inspection, item, organizationName: organizationOf(req)?.name || '',
      });
      document = {
        id: nextId('psage-protocol', inspectionDocuments),
        inspectionId: inspection.id,
        clothingId: item.id,
        fileName: `PSAgE-Pruefprotokoll-${item.inventoryNumber || item.id}-${inspectionDate}.pdf`,
        mimeType: 'application/pdf',
        size: buffer.length,
        contentBase64: buffer.toString('base64'),
        createdAt: inspection.createdAt,
        createdBy: req.user.username,
      };
      inspection.protocolDocumentId = document.id;
    }

    clothingInspections.push(inspection);
    if (document) inspectionDocuments.push(document);
    if (kind === 'expert') {
      item.inspectionIntervalMonths = intervalMonths;
      item.lastInspectionDate = inspectionDate;
      item.lastInspectionResult = inspection.result;
      item.nextInspectionDate = nextInspectionDate;
    }
    if (!inspection.ready) {
      defectManagement.createFromInspection({
        entityType: 'ClothingItem', entityId: item.id, inspectionId: inspection.id,
        notes: [
          `${kind === 'expert' ? 'Sachkundigenprüfung' : 'Sichtprüfung'} PSAgE vom ${inspectionDate}: nicht einsatzbereit.`,
          ...inspection.autoFindings,
          inspection.defectsText,
          inspection.followUp ? `Weiteres Vorgehen: ${inspection.followUp}` : '',
        ].filter(Boolean).join('\n'),
        user: req.user,
      });
    }
    logEvent('inspection', 'ClothingItem', {
      id: item.id, kind, result: inspection.result, psageInspection: inspection.psageInspection,
      protocolArchived: Boolean(document),
    }, req.user.username);
    return res.status(201).json(inspection);
  });

  app.get('/api/clothing/:id/psage-inspections/:inspectionId/pdf', authMiddleware, requirePermission('clothing.read'), async (req, res) => {
    const item = clothingItems.find((entry) => entry.id === req.params.id);
    const inspection = item && clothingInspections.find((entry) =>
      entry.id === req.params.inspectionId && entry.clothingId === item.id && entry.psageChecklist === true);
    if (!inspection) return res.status(404).json({ error: 'Prüfung nicht gefunden.' });
    const archived = inspection.protocolDocumentId
      ? inspectionDocuments.find((entry) => entry.id === inspection.protocolDocumentId)
      : null;
    if (archived) {
      return res.json({
        fileName: archived.fileName, mimeType: archived.mimeType,
        fileBase64: archived.contentBase64, archived: true,
      });
    }
    if (!settingsOf(req).pdfEnabled) {
      return res.status(403).json({ error: 'Der PDF-Prüfnachweis ist in dieser Organisation nicht aktiviert.' });
    }
    const buffer = await generatePsageInspectionPdf({
      inspection, item, organizationName: organizationOf(req)?.name || '',
    });
    return res.json({
      fileName: `PSAgE-Pruefprotokoll-${item.inventoryNumber || item.id}-${inspection.inspectionDate}.pdf`,
      mimeType: 'application/pdf',
      fileBase64: buffer.toString('base64'),
      archived: false,
    });
  });

  return {
    safetyFor: (item) => assessPsageSafety({
      item, category: categoryOf(item), inspections: inspectionsOf(item),
    }),
    isVestCategory: (categoryId) => Boolean(VEST_TYPES[categories.find((entry) => entry.id === categoryId)?.psageVestType]),
  };
}

module.exports = {
  DEFAULT_SETTINGS,
  assessPsageSafety,
  evaluateInspection,
  normalizeManufactureDate,
  normalizePsageSettings,
  registerPsageRoutes,
  vestDetails,
};
