'use strict';

const { INSPECTION_KINDS, RELEASE_TYPES, VEST_TYPES } = require('./psage-checklists');

let pdfLibModule;
function pdfLib() {
  pdfLibModule ||= require('pdf-lib');
  return pdfLibModule;
}

const PAGE_WIDTH = 595.28;
const PAGE_HEIGHT = 841.89;
const MARGIN = 42;
const RATING_LABELS = { na: 'N/A', ok: 'OK', ko: 'KO' };

function formatDate(value) {
  const raw = String(value || '').slice(0, 10);
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(raw);
  return match ? `${match[3]}.${match[2]}.${match[1]}` : (raw || '-');
}

function formatNumber(value) {
  return value === null || value === undefined || value === ''
    ? '-'
    : String(value).replace('.', ',');
}

/**
 * Erstellt das Prüfprotokoll (Dokumentationsnachweis) einer PSAgE-Prüfung.
 * Das PDF wird ausschließlich aus dem gespeicherten Prüfdatensatz erzeugt,
 * damit archivierte und nachträglich erzeugte Protokolle identisch sind.
 */
async function generatePsageInspectionPdf({ inspection, item, organizationName = '' }) {
  const { PDFDocument, StandardFonts, rgb } = pdfLib();
  const document = await PDFDocument.create();
  document.setTitle(`PSAgE-Prüfprotokoll ${item?.inventoryNumber || ''}`.trim());
  document.setCreator('MaterialKompass');
  const font = await document.embedFont(StandardFonts.Helvetica);
  const bold = await document.embedFont(StandardFonts.HelveticaBold);
  const supported = new Set(font.getCharacterSet());
  const safe = (value) => Array.from(String(value ?? ''))
    .map((char) => (char === '\n' || supported.has(char.codePointAt(0)) ? char : '?'))
    .join('')
    .replace(/\r/g, '');

  let page;
  let y;
  const newPage = () => {
    page = document.addPage([PAGE_WIDTH, PAGE_HEIGHT]);
    y = PAGE_HEIGHT - MARGIN;
  };
  const ensure = (height) => {
    if (y - height < MARGIN + 20) newPage();
  };
  const wrap = (value, width, size, usedFont = font) => {
    const lines = [];
    for (const paragraph of safe(value).split('\n')) {
      let line = '';
      for (const word of paragraph.split(/\s+/).filter(Boolean)) {
        const candidate = line ? `${line} ${word}` : word;
        if (usedFont.widthOfTextAtSize(candidate, size) <= width) {
          line = candidate;
        } else {
          if (line) lines.push(line);
          line = word;
          while (usedFont.widthOfTextAtSize(line, size) > width && line.length > 1) {
            let cut = line.length - 1;
            while (cut > 1 && usedFont.widthOfTextAtSize(line.slice(0, cut), size) > width) cut -= 1;
            lines.push(line.slice(0, cut));
            line = line.slice(cut);
          }
        }
      }
      lines.push(line);
    }
    return lines.length ? lines : [''];
  };
  const text = (value, x, size = 9, usedFont = font, color = rgb(0, 0, 0)) => {
    page.drawText(safe(value), { x, y, size, font: usedFont, color });
  };
  const paragraph = (value, size = 9, usedFont = font, indent = 0) => {
    for (const line of wrap(value, PAGE_WIDTH - 2 * MARGIN - indent, size, usedFont)) {
      ensure(size + 4);
      text(line, MARGIN + indent, size, usedFont);
      y -= size + 3;
    }
  };

  newPage();
  const vestType = inspection.vestType;
  const kindLabel = INSPECTION_KINDS[inspection.kind] || 'Prüfung';
  text('PSAgE-Prüfprotokoll', MARGIN, 16, bold);
  y -= 18;
  text(kindLabel, MARGIN, 10, bold);
  y -= 13;
  text(`Checkliste: ${inspection.checklistVersion || '-'}${organizationName ? ` · ${organizationName}` : ''}`, MARGIN, 8);
  y -= 18;

  const vest = inspection.vest || {};
  const facts = [
    ['Bezeichnung', item?.name],
    ['Inventarnummer', item?.inventoryNumber],
    ['Westentyp', VEST_TYPES[vestType]],
    ['Hersteller', vest.manufacturer || item?.manufacturer],
    ['Seriennummer', vest.serialNumber],
    ['Größe', item?.size],
    ['Herstellungsdatum', vest.manufactureDate ? formatDate(vest.manufactureDate) : null],
    ['Auftrieb', vest.buoyancyNewton ? `${vest.buoyancyNewton} N` : null],
    ['Auslösung', vestType === 'lifejacket' ? RELEASE_TYPES[vest.releaseType] : null],
    ['Strömungsretterweste', vestType === 'buoyancy-aid' ? (vest.swiftwaterRescue ? 'Ja' : 'Nein') : null],
    ['Prüfdatum', formatDate(inspection.inspectionDate)],
    ['Prüfer/in', inspection.inspector],
    ['Prüfplakette gültig bis', inspection.serviceTagDueDate ? formatDate(inspection.serviceTagDueDate) : null],
    ['Nächste Prüfung', inspection.nextInspectionDate ? formatDate(inspection.nextInspectionDate) : null],
  ].filter(([, value]) => value !== null && value !== undefined && String(value).trim());
  const columnWidth = (PAGE_WIDTH - 2 * MARGIN) / 2;
  for (let index = 0; index < facts.length; index += 2) {
    ensure(14);
    for (const [offset, entry] of [[0, facts[index]], [1, facts[index + 1]]]) {
      if (!entry) continue;
      const x = MARGIN + offset * columnWidth;
      text(`${entry[0]}:`, x, 9, bold);
      text(wrap(entry[1], columnWidth - 110, 9)[0], x + 105, 9);
    }
    y -= 13;
  }
  y -= 8;

  const columns = { pos: MARGIN, label: MARGIN + 52, na: 360, ok: 385, ko: 410, remark: 438 };
  const labelWidth = columns.na - columns.label - 8;
  const remarkWidth = PAGE_WIDTH - MARGIN - columns.remark;
  const tableHeader = () => {
    ensure(16);
    text('Pos.', columns.pos, 8, bold);
    text('Aspekt', columns.label, 8, bold);
    text('N/A', columns.na, 8, bold);
    text('OK', columns.ok, 8, bold);
    text('KO', columns.ko, 8, bold);
    text('Bemerkung', columns.remark, 8, bold);
    y -= 4;
    page.drawLine({ start: { x: MARGIN, y }, end: { x: PAGE_WIDTH - MARGIN, y }, thickness: 0.6 });
    y -= 10;
  };

  const sections = [];
  for (const entry of inspection.checklist || []) {
    let section = sections.find((candidate) => candidate.id === entry.sectionId);
    if (!section) {
      section = { id: entry.sectionId, title: entry.sectionTitle, entries: [] };
      sections.push(section);
    }
    section.entries.push(entry);
  }
  for (const section of sections) {
    ensure(46);
    y -= 6;
    text(section.title || '', MARGIN, 10, bold);
    y -= 14;
    tableHeader();
    for (const entry of section.entries) {
      const labelLines = wrap(entry.label, labelWidth, 8);
      const remarkLines = wrap(entry.remark || '', remarkWidth, 7);
      const height = Math.max(labelLines.length * 10, remarkLines.length * 9, 10) + 4;
      if (y - height < MARGIN + 20) {
        newPage();
        tableHeader();
      }
      const top = y;
      text(entry.position, columns.pos, 8);
      labelLines.forEach((line, index) => {
        page.drawText(line, { x: columns.label, y: top - index * 10, size: 8, font });
      });
      const ratingColumn = columns[entry.rating];
      if (ratingColumn) {
        page.drawText('X', {
          x: ratingColumn + 4, y: top, size: 9, font: bold,
          color: entry.rating === 'ko' ? rgb(0.75, 0, 0) : rgb(0, 0, 0),
        });
      }
      remarkLines.forEach((line, index) => {
        page.drawText(line, { x: columns.remark, y: top - index * 9, size: 7, font });
      });
      y = top - height + 6;
      page.drawLine({
        start: { x: MARGIN, y: y + 2 }, end: { x: PAGE_WIDTH - MARGIN, y: y + 2 },
        thickness: 0.2, color: rgb(0.6, 0.6, 0.6),
      });
      y -= 8;
    }
    if (section.id === 'B' && inspection.measurements) {
      const m = inspection.measurements;
      ensure(60);
      y -= 2;
      paragraph(`Gas: ${m.gasType || '-'}`, 8, bold, 52);
      paragraph(`Mindest-Bruttomasse: ${formatNumber(m.grossMass)} ± ${formatNumber(m.grossTolerance)} g`, 8, font, 52);
      paragraph(`+ Masse des Gasinhalts: ${formatNumber(m.gasMass)} ± ${formatNumber(m.gasTolerance)} g`, 8, font, 52);
      paragraph(`= Soll gesamt: ${formatNumber(m.expectedMass)} ± ${formatNumber(m.expectedTolerance)} g`, 8, font, 52);
      paragraph(`Ist: ${formatNumber(m.actualMass)} g${m.withinTolerance === false ? ' – außerhalb der Toleranz' : m.withinTolerance === true ? ' – innerhalb der Toleranz' : ''}`, 8, bold, 52);
      y -= 6;
    }
  }

  ensure(80);
  y -= 6;
  page.drawLine({ start: { x: MARGIN, y: y + 8 }, end: { x: PAGE_WIDTH - MARGIN, y: y + 8 }, thickness: 0.6 });
  y -= 6;
  const readyMark = inspection.ready ? 'X' : ' ';
  const notReadyMark = inspection.ready ? ' ' : 'X';
  paragraph(`[${readyMark}] Die vorliegende PSAgE ist gemäß der durchgeführten Prüfung einsatzbereit.`, 9, inspection.ready ? bold : font);
  paragraph(`[${notReadyMark}] Die vorliegende PSAgE ist nicht einsatzbereit. Festgestellte Mängel und Anweisungen zum weiteren Vorgehen:`, 9, inspection.ready ? font : bold);
  for (const finding of inspection.autoFindings || []) paragraph(`- ${finding}`, 8, font, 14);
  if (inspection.defectsText) paragraph(inspection.defectsText, 8, font, 14);
  if (inspection.followUp) paragraph(`Weiteres Vorgehen: ${inspection.followUp}`, 8, font, 14);
  if (inspection.remarks) paragraph(`Bemerkungen: ${inspection.remarks}`, 8, font, 14);

  ensure(50);
  y -= 30;
  page.drawLine({ start: { x: MARGIN, y: y + 10 }, end: { x: MARGIN + 200, y: y + 10 }, thickness: 0.5 });
  page.drawLine({ start: { x: PAGE_WIDTH - MARGIN - 200, y: y + 10 }, end: { x: PAGE_WIDTH - MARGIN, y: y + 10 }, thickness: 0.5 });
  text('Ort, Datum', MARGIN, 7);
  text(`Unterschrift ${inspection.inspector || ''}`, PAGE_WIDTH - MARGIN - 200, 7);

  const pages = document.getPages();
  pages.forEach((entry, index) => {
    entry.drawText(safe(`Erstellt mit MaterialKompass · Prüfung ${inspection.id} · Seite ${index + 1} von ${pages.length}`), {
      x: MARGIN, y: 22, size: 7, font, color: rgb(0.4, 0.4, 0.4),
    });
  });
  return Buffer.from(await document.save());
}

module.exports = { generatePsageInspectionPdf };
