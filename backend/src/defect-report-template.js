const { PDFDocument, StandardFonts, rgb } = require('pdf-lib');

const PAGE_WIDTH = 595.28;
const PAGE_HEIGHT = 841.89;
const MARGIN = 42;
const LABEL_WIDTH = 128;
const BORDER = rgb(0.18, 0.18, 0.18);
const ACCENT = rgb(0.03, 0.36, 0.55);

function drawText(page, font, value, x, y, size = 10, options = {}) {
  page.drawText(String(value), {
    x, y, size, font,
    color: options.color || BORDER,
    maxWidth: options.maxWidth,
  });
}

function drawHeader(page, bold, title, pageNumber) {
  drawText(page, bold, title, MARGIN, PAGE_HEIGHT - 56, 19, { color: ACCENT });
  page.drawLine({
    start: { x: MARGIN, y: PAGE_HEIGHT - 70 },
    end: { x: PAGE_WIDTH - MARGIN, y: PAGE_HEIGHT - 70 },
    thickness: 1.5,
    color: ACCENT,
  });
  drawText(
    page,
    bold,
    `MaterialKompass | maengel@materialkompass.org | Seite ${pageNumber}`,
    MARGIN,
    25,
    8,
    { color: rgb(0.35, 0.35, 0.35) },
  );
}

function addTextRow({ page, form, font, bold, name, label, y, height, value = '', multiline = false }) {
  page.drawRectangle({
    x: MARGIN,
    y,
    width: PAGE_WIDTH - 2 * MARGIN,
    height,
    borderWidth: 0.8,
    borderColor: BORDER,
  });
  page.drawLine({
    start: { x: MARGIN + LABEL_WIDTH, y },
    end: { x: MARGIN + LABEL_WIDTH, y: y + height },
    thickness: 0.8,
    color: BORDER,
  });
  const labelLines = label.split('\n');
  labelLines.forEach((line, index) => {
    drawText(page, bold, line, MARGIN + 8, y + height - 18 - index * 13, 9.5);
  });
  const field = form.createTextField(name);
  field.setText(String(value || ''));
  if (multiline) field.enableMultiline();
  field.addToPage(page, {
    x: MARGIN + LABEL_WIDTH + 5,
    y: y + 5,
    width: PAGE_WIDTH - 2 * MARGIN - LABEL_WIDTH - 10,
    height: height - 10,
    borderWidth: 0,
    textColor: BORDER,
    font,
  });
  field.setFontSize(multiline ? 10 : 11);
}

function addCheckbox({ page, form, font, name, label, x, y, checked = false }) {
  const field = form.createCheckBox(name);
  field.addToPage(page, {
    x,
    y,
    width: 13,
    height: 13,
    borderWidth: 0.9,
    borderColor: BORDER,
  });
  if (checked) field.check();
  drawText(page, font, label, x + 19, y + 1, 10);
}

async function generateDefectReportPdf({
  inventoryNumber = '',
  contactName = '',
  contactEmail = '',
} = {}) {
  const document = await PDFDocument.create();
  document.setTitle('Mängelbericht für Material oder Kleidung');
  document.setAuthor('MaterialKompass');
  document.setSubject('Mängelmeldung per E-Mail');
  document.setKeywords(['MaterialKompass', 'Mängelbericht', 'Inventar', 'Kleidung']);
  const font = await document.embedFont(StandardFonts.Helvetica);
  const bold = await document.embedFont(StandardFonts.HelveticaBold);
  const form = document.getForm();

  const first = document.addPage([PAGE_WIDTH, PAGE_HEIGHT]);
  drawHeader(first, bold, 'Mängelbericht für Material oder Kleidung', 1);
  drawText(first, font, 'Pflichtfelder sind mit * gekennzeichnet.', MARGIN, PAGE_HEIGHT - 91, 9);
  addTextRow({
    page: first, form, font, bold, name: 'Inventarnummer', label: 'Inventarnummer *',
    y: 663, height: 48, value: inventoryNumber,
  });
  addTextRow({
    page: first, form, font, bold, name: 'Name', label: 'Name *',
    y: 615, height: 48, value: contactName,
  });
  addTextRow({
    page: first, form, font, bold, name: 'E-Mailadresse', label: 'E-Mailadresse *',
    y: 567, height: 48, value: contactEmail,
  });
  addTextRow({
    page: first, form, font, bold, name: 'Telefonnummer', label: 'Telefonnummer',
    y: 519, height: 48,
  });
  drawText(first, bold, 'Angaben zum Mangel', MARGIN, 493, 12, { color: ACCENT });
  addTextRow({
    page: first, form, font, bold, name: 'Beschreibung_des_Mangels',
    label: 'Beschreibung des\nMangels *', y: 218, height: 260, multiline: true,
  });
  addTextRow({
    page: first, form, font, bold, name: 'Getroffene_Maßnahmen',
    label: 'Getroffene\nMaßnahmen', y: 105, height: 113, multiline: true,
  });
  addTextRow({
    page: first, form, font, bold, name: 'Datum_der_Feststellung',
    label: 'Datum der\nFeststellung', y: 57, height: 48,
  });

  const second = document.addPage([PAGE_WIDTH, PAGE_HEIGHT]);
  drawHeader(second, bold, 'Status und Gefährdung', 2);
  second.drawRectangle({
    x: MARGIN, y: 665, width: PAGE_WIDTH - 2 * MARGIN, height: 74,
    borderWidth: 0.8, borderColor: BORDER,
  });
  drawText(second, bold, 'Einsatzbereitschaft *', MARGIN + 8, 711, 10);
  addCheckbox({
    page: second, form, font, name: 'Nicht_einsatzfaehig',
    label: 'Nicht einsatzfähig', x: 184, y: 701,
  });
  addCheckbox({
    page: second, form, font, name: 'Eingeschraenkt',
    label: 'Eingeschränkt', x: 326, y: 701,
  });
  addCheckbox({
    page: second, form, font, name: 'Einsatzfaehig',
    label: 'Einsatzfähig', x: 447, y: 701,
  });
  drawText(second, bold, 'Gefährdungsstufe', MARGIN + 8, 676, 10);
  addCheckbox({
    page: second, form, font, name: 'Gefaehrdung_Niedrig',
    label: 'Niedrig', x: 184, y: 668,
  });
  addCheckbox({
    page: second, form, font, name: 'Gefaehrdung_Mittel',
    label: 'Mittel', x: 270, y: 668,
  });
  addCheckbox({
    page: second, form, font, name: 'Gefaehrdung_Hoch',
    label: 'Hoch', x: 350, y: 668,
  });
  drawText(second, bold, 'Weitere Hinweise', MARGIN, 634, 12, { color: ACCENT });
  const notes = form.createTextField('Weitere_Hinweise');
  notes.enableMultiline();
  notes.addToPage(second, {
    x: MARGIN,
    y: 465,
    width: PAGE_WIDTH - 2 * MARGIN,
    height: 155,
    borderWidth: 0.8,
    borderColor: BORDER,
    textColor: BORDER,
    font,
  });
  notes.setFontSize(10);
  drawText(second, bold, 'Abgabe / Versand:', MARGIN, 435, 10);
  drawText(
    second,
    font,
    'Bitte genau einen ausgefüllten Bericht sowie optionale Schadensbilder als Anhang an',
    MARGIN + 94,
    435,
    9.5,
  );
  drawText(second, bold, 'maengel@materialkompass.org', MARGIN, 419, 10, { color: ACCENT });
  drawText(
    second,
    font,
    'senden. Unterstützt werden PDF, PNG und JPEG.',
    MARGIN + 154,
    419,
    9.5,
  );

  form.updateFieldAppearances(font);
  return Buffer.from(await document.save({ useObjectStreams: false }));
}

module.exports = { generateDefectReportPdf };
