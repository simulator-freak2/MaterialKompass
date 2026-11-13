'use strict';

/**
 * Fest hinterlegte Prüfchecklisten für persönliche Schutzausrüstung gegen
 * Ertrinken (PSAgE) nach der Prüfungs-Checkliste „Westenkunde“ des
 * DLRG LV Hessen Bootswesen, Stand 2023-1 (Anlehnung an Merkblatt SuG 05-22).
 *
 * Jede gespeicherte Prüfung hält die verwendete Version fest, damit ältere
 * Nachweise auch nach einer späteren Neuauflage nachvollziehbar bleiben.
 */
const PSAGE_CHECKLIST_VERSION = 'LV-Hessen-Westenkunde-2023-1';

const VEST_TYPES = Object.freeze({
  'buoyancy-aid': 'Schwimm-, Auftriebshilfe oder Prallschutzweste',
  lifejacket: 'Rettungsweste (aufblasbar)',
});

const RELEASE_TYPES = Object.freeze({
  automatic: 'Automatische Auslösung',
  manual: 'Manuelle Auslösung',
});

const BUOYANCY_VALUES = Object.freeze([50, 70, 100, 150, 275]);

// Altersgrenzen ab Herstellungsdatum.
const AGE_LIMITS = Object.freeze({
  'buoyancy-aid': { blockYears: 10 },
  lifejacket: { biennialYears: 10, blockYears: 15 },
});

// Rückfallintervalle, falls die Kategorie kein Prüfintervall festlegt.
const DEFAULT_INTERVAL_MONTHS = Object.freeze({
  'buoyancy-aid': 12,
  lifejacket: 24,
});

const item = (id, position, label, options = {}) => ({ id, position, label, ...options });

const EXPERT_CHECKLISTS = Object.freeze({
  'buoyancy-aid': {
    title: 'Überprüfung einer Schwimm-, Auftriebshilfe oder Prallschutzweste',
    sections: [
      {
        id: 'main',
        title: 'Prüfung',
        items: [
          item('ba-manufacture-age', 'NEU', 'Herstellungsdatum nicht älter als 10 Jahre'),
          item('ba-1.2', '1.2', 'Zustand des Auftriebskörpers (Risse, Knicke, Verschmutzung und hygienischer Zustand)'),
          item('ba-feel', 'NEU', 'Anfühlen des Auftriebskörpers: keine Brüche / Brösel'),
          item('ba-3.5', '3.5', 'Zustand der Nähte'),
          item('ba-1.6', '1.6', 'Zustand und Vollständigkeit der Beschläge'),
          item('ba-swiftwater', 'NEU', 'Strömungsretterweste: Notauslösemechanismus', { requires: 'swiftwater' }),
          item('ba-3.2', '3.2', 'Zustand von Riemen und Bändern'),
          item('ba-3.3', '3.3', 'Zustand und Funktion des Gurtschlosses bzw. der Gurtschlösser'),
          item('ba-3.4', '3.4', 'Zustand des Leibgurtes'),
          item('ba-crotch', 'NEU', 'Zustand des Schrittgurtes'),
          item('ba-1.4', '1.4', 'Kurzbedienungsanleitung vorhanden und lesbar'),
          item('ba-4.1', '4.1', 'Signalpfeife vorhanden und funktionsfähig'),
          item('ba-4.2', '4.2', 'Funkellicht vorhanden'),
        ],
      },
    ],
  },
  lifejacket: {
    title: 'Überprüfung einer Rettungsweste',
    sections: [
      {
        id: 'A',
        title: 'A. Prüfung von außen',
        items: [
          item('lj-4.3', '4.3', 'Prüfplakette vorhanden und unbeschädigt'),
          item('lj-1.1', '1.1', 'Einhaltung des Wartungsintervalls gemäß Plakette/Tabelle'),
          item('lj-1.4', '1.4', 'Kurzbedienungsanleitung vorhanden'),
          item('lj-1.6', '1.6', 'Zustand und Vollständigkeit der Beschläge'),
          item('lj-3.2', '3.2', 'Zustand von Riemen und Bändern'),
          item('lj-3.3', '3.3', 'Zustand und Funktion des Gurtschlosses'),
          item('lj-3.4', '3.4', 'Zustand des Leibgurtes'),
          item('lj-3.5', '3.5', 'Zustand der Nähte'),
        ],
      },
      {
        id: 'B',
        title: 'B. Nach Entnahme Druckgasbehälter',
        measurements: true,
        items: [
          item('lj-2.1', '2.1', 'Vorgeschriebene Druckgasflasche vorhanden (Herstellerangaben beachten)'),
          item('lj-2.2', '2.2 & 2.3', 'Druckgasflasche unversehrt und Verschlussplättchen unbeschädigt'),
          item('lj-2.14', '2.14', 'Chemische Formel des in der Druckgasflasche enthaltenen Gases (z. B. CO2)'),
          item('lj-2.13', '2.13 & 2.11', 'Mindest-Bruttomasse und Masse des Gasinhalts der Druckgasflasche (in g)'),
          item('lj-2.12', '2.12', 'Füllstand des Druckgasbehälters (Patrone mit Küchenwaage wiegen)'),
        ],
      },
      {
        id: 'C',
        title: 'C. Auftriebskörper',
        items: [
          item('lj-3.1', '3.1', 'Zustand retroreflektierendes Material'),
          item('lj-4.1', '4.1', 'Signalpfeife vorhanden und funktionsfähig'),
          item('lj-4.2', '4.2', 'Funkellicht vorhanden und funktionsfähig'),
          item('lj-table', 'NEU', 'Tabelle Wartungsdatum und Identifikationsnummer vorhanden und lesbar'),
          item('lj-1.3', '1.3', 'Zustand der Mundaufblasevorrichtung bzw. Ablassventil (Beschädigung/Funktion Rückschlagventil)'),
          item('lj-1.2', '1.2', 'Zustand des Auftriebskörpers (Risse, Knicke, Verschmutzung und hygienischer Zustand)'),
          item('lj-1.7', '1.7', 'Richtigkeit der Faltung der aufblasbaren Auftriebskörper und ordnungsgemäß geschlossen'),
        ],
      },
      {
        id: 'D',
        title: 'D. Auslösevorrichtung',
        items: [
          item('lj-1.5', '1.5', 'Schutzhülle der Auslösevorrichtung unbeschädigt'),
          item('lj-2.5', '2.5', 'Zustand des Auslösevorrichtungsgehäuses (Schäden, Risse, Korrosion u. Ä.)'),
          item('lj-2.6', '2.6', 'Art des Auslösemechanismus (automatische/manuelle Auslösung) entspricht der Kennzeichnung'),
          item('lj-2.7', '2.7', 'Handauslösung betriebsbereit (metallener Handauslösehebel an der Reißleine nicht sichtbar), ins Gehäuse eingeklappt und durch Sicherungsbügel (grün) gesichert'),
          item('lj-2.8', '2.8', 'Auslösetablette funktionsbereit in Tablettenschieber eingelegt und Auslösevorrichtung durch Spannen und Einklappen des Spannhebels funktionsbereit (grüne Markierung sichtbar)', { requires: 'automatic' }),
          item('lj-2.9', '2.9', 'Befestigungsschraube der Auslösevorrichtung durch eine Plastikkappe geschützt'),
        ],
      },
      {
        id: 'E',
        title: 'E. Wiedereinsetzen des Druckgasbehälters',
        items: [
          item('lj-2.4', '2.4', 'Druckgasbehälter richtig und handfest eingeschraubt (grüne Markierung sichtbar)'),
          item('lj-2.10', '2.10', 'Zustand aller Indikatoren (alle grün?)'),
        ],
      },
    ],
  },
});

// Sichtprüfung durch den Nutzer bzw. Buddy-Check vor der Verwendung,
// abgeleitet aus den KO-Kriterien und dem Zusatzbogen der Westenkunde.
const VISUAL_CHECKLISTS = Object.freeze({
  'buoyancy-aid': {
    title: 'Sichtprüfung durch den Nutzer · Schwimm-, Auftriebshilfe oder Prallschutzweste',
    sections: [
      {
        id: 'visual',
        title: 'Sichtprüfung',
        items: [
          item('vba-age', 'S1', 'Herstellungsdatum nicht älter als 10 Jahre'),
          item('vba-body', 'S2', 'Auftriebskörper ohne Risse, Knicke, Brüche oder starke Verschmutzung'),
          item('vba-straps', 'S3', 'Nähte, Riemen, Bänder und Gurtschlösser unbeschädigt und funktionsfähig'),
          item('vba-crotch', 'S4', 'Schrittgurt (falls vorhanden) unbeschädigt und angelegt'),
          item('vba-swiftwater', 'S5', 'Notauslösemechanismus der Strömungsretterweste frei und funktionsfähig', { requires: 'swiftwater' }),
          item('vba-fit', 'S6', 'Weste passend zu Träger und wettergemäßer Kleidung und korrekt angelegt'),
        ],
      },
    ],
  },
  lifejacket: {
    title: 'Sichtprüfung durch den Nutzer · Rettungsweste',
    sections: [
      {
        id: 'visual',
        title: 'Sichtprüfung',
        items: [
          item('vlj-tag', 'S1', 'Prüfplakette vorhanden und nicht abgelaufen'),
          item('vlj-indicators', 'S2', 'Alle herstellerspezifischen Indikatoren grün (soweit mit vertretbarem Aufwand sichtbar)'),
          item('vlj-cylinder', 'S3', 'Druckgaspatrone unversehrt, nicht verbraucht und korrekt eingeschraubt'),
          item('vlj-folded', 'S4', 'Ordnungsgemäß gefaltet und geschlossen'),
          item('vlj-straps', 'S5', 'Nähte, Riemen, Bänder und Gurtschloss ohne sichtbare Beschädigung'),
          item('vlj-crotch', 'S6', 'Schrittgurt (falls vorhanden) unbeschädigt und angelegt'),
          item('vlj-fit', 'S7', 'Korrekt angelegt (max. zwei Finger zwischen Brust und Bebänderung), nie unter der Kleidung, nie mit offenem Verschluss'),
        ],
      },
    ],
  },
});

const INSPECTION_KINDS = Object.freeze({
  expert: 'Regelmäßig wiederkehrende Prüfung durch einen Sachkundigen',
  visual: 'Sichtprüfung durch den Nutzer',
});

function applicableChecklist(kind, vestType, vest = {}) {
  const source = (kind === 'visual' ? VISUAL_CHECKLISTS : EXPERT_CHECKLISTS)[vestType];
  if (!source) return null;
  const applies = (entry) => {
    if (entry.requires === 'swiftwater') return vest.swiftwaterRescue === true;
    if (entry.requires === 'automatic') return vest.releaseType !== 'manual';
    return true;
  };
  return {
    kind,
    vestType,
    version: PSAGE_CHECKLIST_VERSION,
    title: source.title,
    sections: source.sections.map((section) => ({
      ...section,
      items: section.items.filter(applies).map(({ requires, ...rest }) => rest),
    })),
  };
}

function publicChecklists() {
  const build = (kind, collection) => Object.fromEntries(
    Object.entries(collection).map(([vestType, definition]) => [vestType, {
      title: definition.title,
      sections: definition.sections,
    }]),
  );
  return {
    version: PSAGE_CHECKLIST_VERSION,
    vestTypes: VEST_TYPES,
    releaseTypes: RELEASE_TYPES,
    buoyancyValues: BUOYANCY_VALUES,
    inspectionKinds: INSPECTION_KINDS,
    ageLimits: AGE_LIMITS,
    defaultIntervalMonths: DEFAULT_INTERVAL_MONTHS,
    expert: build('expert', EXPERT_CHECKLISTS),
    visual: build('visual', VISUAL_CHECKLISTS),
  };
}

module.exports = {
  AGE_LIMITS,
  BUOYANCY_VALUES,
  DEFAULT_INTERVAL_MONTHS,
  INSPECTION_KINDS,
  PSAGE_CHECKLIST_VERSION,
  RELEASE_TYPES,
  VEST_TYPES,
  applicableChecklist,
  publicChecklists,
};
