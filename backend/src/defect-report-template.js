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

  if (inventoryNumber || contactName || contactEmail) {
    const font = await document.embedFont(StandardFonts.Helvetica);
    const form = document.getForm();
    form.getTextField('Inventarnummer').setText(String(inventoryNumber || ''));
    form.getTextField('Name').setText(String(contactName || ''));
    form.getTextField('E-Mailadresse').setText(String(contactEmail || ''));
    form.updateFieldAppearances(font);
  }

  return Buffer.from(await document.save({ useObjectStreams: false }));
}

module.exports = { generateDefectReportPdf };
