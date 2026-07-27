const { readFile } = require('node:fs/promises');
const path = require('node:path');
const { PDFDocument, StandardFonts } = require('pdf-lib');

const TEMPLATE_PATH = path.join(__dirname, 'assets', 'maengelbericht-material.pdf');

async function generateDefectReportPdf({
  inventoryNumber = '',
  contactName = '',
  contactEmail = '',
} = {}) {
  const template = await readFile(TEMPLATE_PATH);
  if (!inventoryNumber && !contactName && !contactEmail) return Buffer.from(template);

  const document = await PDFDocument.load(template);
  const font = await document.embedFont(StandardFonts.Helvetica);
  const form = document.getForm();
  form.getTextField('Inventarnummer').setText(String(inventoryNumber || ''));
  form.getTextField('Name').setText(String(contactName || ''));
  form.getTextField('E-Mailadresse').setText(String(contactEmail || ''));
  form.updateFieldAppearances(font);

  return Buffer.from(await document.save({ useObjectStreams: false }));
}

module.exports = { generateDefectReportPdf };
