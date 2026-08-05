const { readFile } = require('node:fs/promises');
const path = require('node:path');
const { PDFDocument, StandardFonts } = require('pdf-lib');

const TEMPLATE_PATH = path.join(__dirname, 'assets', 'maengelbericht-material.pdf');
const LOGO_PATH = path.join(
  __dirname,
  'assets',
  'materialkompass-logo-with-wordmark.png',
);

async function generateDefectReportPdf({
  inventoryNumber = '',
  contactName = '',
  contactEmail = '',
  contactPhone = '',
  reportedAt = '',
  description = '',
  measuresTaken = '',
  notes = '',
  operationalSafety = '',
  riskLevel = '',
  details = [],
} = {}) {
  const [template, logoBytes] = await Promise.all([
    readFile(TEMPLATE_PATH),
    readFile(LOGO_PATH),
  ]);

  const document = await PDFDocument.load(template);
  const logo = await document.embedPng(logoBytes);
  const firstPage = document.getPages()[0];
  const logoWidth = 210;
  const logoHeight = logoWidth * (logo.height / logo.width);
  firstPage.drawImage(logo, {
    x: (firstPage.getWidth() - logoWidth) / 2,
    y: firstPage.getHeight() - logoHeight,
    width: logoWidth,
    height: logoHeight,
  });

  const printableDetails = details
    .filter((entry) => entry && entry.value !== null && entry.value !== undefined && String(entry.value).trim())
    .map((entry) => ({ label: String(entry.label || ''), value: String(entry.value) }));
  const hasPrefill = [
    inventoryNumber, contactName, contactEmail, contactPhone, reportedAt,
    description, measuresTaken, notes, operationalSafety, riskLevel,
  ].some((value) => String(value || '').trim());
  if (!hasPrefill && !printableDetails.length) {
    return Buffer.from(await document.save({ useObjectStreams: false }));
  }

  const font = await document.embedFont(StandardFonts.Helvetica);
  const boldFont = await document.embedFont(StandardFonts.HelveticaBold);
  if (hasPrefill) {
    const form = document.getForm();
    const setText = (name, value) => form.getTextField(name).setText(String(value || ''));
    setText('Inventarnummer', inventoryNumber);
    setText('Name', contactName);
    setText('E-Mailadresse', contactEmail);
    setText('Telefonnummer', contactPhone);
    setText('Datum derFeststellung', reportedAt);
    setText('Beschreibung_des_Mangels', description);
    setText('Getroffene_Maßnahmen', measuresTaken);
    setText('Weitere Hinweise', notes);
    const normalizedSafety = String(operationalSafety).toLowerCase();
    if (normalizedSafety.includes('nicht')) form.getCheckBox('Einsatzbereitschaft_nicht_einsatzfähig').check();
    else if (normalizedSafety.includes('eingeschr')) form.getCheckBox('Einsatzbereitschaft_eingeschraenkt').check();
    else if (normalizedSafety.includes('einsatzbereit')) form.getCheckBox('Einsatzbereitschaft_einsatzbereit').check();
    const normalizedRisk = String(riskLevel).toLowerCase();
    if (normalizedRisk.includes('hoch') || normalizedRisk.includes('krit')) form.getCheckBox('gefaehrdungsstufe_hoch').check();
    else if (normalizedRisk.includes('mittel')) form.getCheckBox('gefaehrdungsstufe_mittel').check();
    else if (normalizedRisk.includes('niedrig')) form.getCheckBox('gefaehrdungsstufe_niedrig').check();
    form.updateFieldAppearances(font);
  }

  if (printableDetails.length) {
    const pageWidth = 595.28;
    const pageHeight = 841.89;
    const margin = 46;
    const maxWidth = pageWidth - (margin * 2);
    const fontSize = 9;
    const lineHeight = 13;
    const wrap = (value, width) => {
      const result = [];
      for (const paragraph of String(value).replace(/\r/g, '').split('\n')) {
        const words = paragraph.split(/\s+/).filter(Boolean);
        let line = '';
        for (const word of words) {
          const candidate = line ? `${line} ${word}` : word;
          if (font.widthOfTextAtSize(candidate, fontSize) <= width || !line) line = candidate;
          else { result.push(line); line = word; }
        }
        result.push(line);
      }
      return result.length ? result : [''];
    };
    let page;
    let y;
    const newPage = () => {
      page = document.addPage([pageWidth, pageHeight]);
      y = pageHeight - margin;
      page.drawText('Vollständige Mängeldokumentation', { x: margin, y, size: 15, font: boldFont });
      y -= 25;
    };
    newPage();
    for (const entry of printableDetails) {
      const labelLines = wrap(`${entry.label}:`, maxWidth);
      const valueLines = wrap(entry.value, maxWidth - 12);
      const needed = (labelLines.length + valueLines.length) * lineHeight + 8;
      if (y - needed < margin) newPage();
      for (const line of labelLines) {
        page.drawText(line, { x: margin, y, size: fontSize, font: boldFont });
        y -= lineHeight;
      }
      for (const line of valueLines) {
        page.drawText(line, { x: margin + 12, y, size: fontSize, font });
        y -= lineHeight;
      }
      y -= 7;
    }
  }

  return Buffer.from(await document.save({ useObjectStreams: false }));
}

module.exports = { generateDefectReportPdf };
