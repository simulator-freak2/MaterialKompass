const { createHash, randomUUID } = require('node:crypto');
const { simpleParser } = require('mailparser');
const sharp = require('sharp');
const {
  PDFDocument,
  PDFCheckBox,
  PDFTextField,
} = require('pdf-lib');
const { createWorker, OEM, PSM } = require('tesseract.js');
const germanLanguage = require('@tesseract.js-data/deu');
const { createCanvas, DOMMatrix, ImageData, Path2D } = require('@napi-rs/canvas');
const { generateDefectReportPdf } = require('./defect-report-template');

const MAX_MESSAGE_BYTES = 25 * 1024 * 1024;
const MAX_ATTACHMENTS_BYTES = 20 * 1024 * 1024;
const MAX_REPORT_BYTES = 10 * 1024 * 1024;
const MAX_IMAGE_BYTES = 8 * 1024 * 1024;
const MAX_IMAGES = 10;
const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const OPERATIONAL_SAFETY = new Set([
  'Nicht einsatzfähig',
  'Eingeschränkt',
  'Einsatzfähig',
]);
const REPORT_ANCHORS = [
  'mängelbericht',
  'inventarnummer',
  'beschreibung des mangels',
  'getroffene maßnahmen',
  'status und gefährdung',
  'einsatzbereitschaft',
  'gefährdungsstufe',
  'weitere hinweise',
];

function normalizeText(value) {
  return String(value || '')
    .normalize('NFKC')
    .replace(/\r/g, '')
    .replace(/[ \t]+/g, ' ')
    .trim();
}

function normalizedSearch(value) {
  return normalizeText(value)
    .toLocaleLowerCase('de')
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .replace(/[^a-z0-9@.+-]+/g, ' ');
}

function normalizeInventoryNumber(value) {
  return String(value || '').toLocaleUpperCase('de').replace(/[^A-Z0-9]/g, '');
}

function magicType(bytes) {
  if (bytes.subarray(0, 5).toString('ascii') === '%PDF-') return 'application/pdf';
  if (bytes.length >= 8
    && bytes.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))) {
    return 'image/png';
  }
  if (bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) {
    return 'image/jpeg';
  }
  if (bytes.length >= 12
    && bytes.subarray(0, 4).toString('ascii') === 'RIFF'
    && bytes.subarray(8, 12).toString('ascii') === 'WEBP') return 'image/webp';
  if (bytes.length >= 12 && bytes.subarray(4, 8).toString('ascii') === 'ftyp') {
    const brand = bytes.subarray(8, 12).toString('ascii').toLowerCase();
    if (['heic', 'heix', 'hevc', 'hevx', 'mif1', 'msf1'].includes(brand)) return 'image/heic';
  }
  return null;
}

function safeFileName(value, fallback) {
  return String(value || fallback)
    .replace(/[<>:"/\\|?*\u0000-\u001f]/g, '_')
    .slice(0, 180);
}

function replaceExtension(fileName, extension) {
  return `${String(fileName).replace(/\.[^.]+$/, '')}.${extension}`;
}

function reportScore(text) {
  const searchable = normalizedSearch(text);
  return REPORT_ANCHORS.reduce((score, anchor) =>
    score + (searchable.includes(normalizedSearch(anchor)) ? 1 : 0), 0);
}

function lineValue(text, label, followingLabels = []) {
  const escaped = label.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const stops = followingLabels
    .map((value) => value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'))
    .join('|');
  const pattern = stops
    ? new RegExp(`${escaped}\\s*[:\\-]?\\s*([\\s\\S]*?)(?=\\n\\s*(?:${stops})\\b|$)`, 'i')
    : new RegExp(`${escaped}\\s*[:\\-]?\\s*([^\\n]+)`, 'i');
  return normalizeText(text.match(pattern)?.[1] || '');
}

function findItem(inventoryNumber, materials, clothingItems) {
  const wanted = normalizeInventoryNumber(inventoryNumber);
  if (!wanted) return null;
  const candidates = [
    ...materials.map((item) => ({ item, entityType: 'MaterialItem' })),
    ...clothingItems.map((item) => ({ item, entityType: 'ClothingItem' })),
  ].filter(({ item }) => normalizeInventoryNumber(item.inventoryNumber) === wanted);
  return candidates.length === 1 ? candidates[0] : null;
}

function findItemInText(text, materials, clothingItems) {
  const searchable = normalizeInventoryNumber(text);
  const candidates = [
    ...materials.map((item) => ({ item, entityType: 'MaterialItem' })),
    ...clothingItems.map((item) => ({ item, entityType: 'ClothingItem' })),
  ].filter(({ item }) => {
    const inventoryNumber = normalizeInventoryNumber(item.inventoryNumber);
    return inventoryNumber.length >= 4 && searchable.includes(inventoryNumber);
  });
  return candidates.length === 1 ? candidates[0] : null;
}

function operationalSafetyFromText(text) {
  const searchable = normalizedSearch(text);
  const checkedPatterns = [
    ['Nicht einsatzfähig', /(?:x|✓|☒|■)\s*nicht einsatzfahig|nicht einsatzfahig\s*(?:x|✓|☒|■)/i],
    ['Eingeschränkt', /(?:x|✓|☒|■)\s*eingeschrankt|eingeschrankt\s*(?:x|✓|☒|■)/i],
    ['Einsatzfähig', /(?:x|✓|☒|■)\s*einsatzfahig|einsatzfahig\s*(?:x|✓|☒|■)/i],
  ];
  const checked = checkedPatterns.filter(([, pattern]) => pattern.test(searchable));
  return checked.length === 1 ? checked[0][0] : '';
}

function riskFromText(text) {
  const searchable = normalizedSearch(text);
  for (const [value, pattern] of [
    ['Hoch', /(?:x|✓|☒|■)\s*hoch|hoch\s*(?:x|✓|☒|■)/i],
    ['Mittel', /(?:x|✓|☒|■)\s*mittel|mittel\s*(?:x|✓|☒|■)/i],
    ['Niedrig', /(?:x|✓|☒|■)\s*niedrig|niedrig\s*(?:x|✓|☒|■)/i],
  ]) {
    if (pattern.test(searchable)) return value;
  }
  return 'Keine Angabe';
}

function extractFromText(text, materials, clothingItems) {
  const itemMatch = findItemInText(text, materials, clothingItems);
  const email = text.match(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/i)?.[0] || '';
  const description = lineValue(text, 'Beschreibung des Mangels', [
    'Getroffene Maßnahmen',
    'Datum der Feststellung',
    'Status und Gefährdung',
  ]);
  const contactName = lineValue(text, 'Name', ['E-Mailadresse', 'E-Mail-Adresse', 'Telefonnummer']);
  return {
    inventoryNumber: itemMatch?.item.inventoryNumber || '',
    description,
    operationalSafety: operationalSafetyFromText(text),
    contactName,
    contactEmail: email.toLowerCase(),
    contactPhone: lineValue(text, 'Telefonnummer', ['Angaben zum Mangel', 'Beschreibung']),
    cause: lineValue(text, 'Getroffene Maßnahmen', ['Datum der Feststellung', 'Status und Gefährdung']),
    riskLevel: riskFromText(text),
    entityType: itemMatch?.entityType || '',
    entityId: itemMatch?.item.id || '',
  };
}

function mergeExtracted(primary, fallback) {
  return Object.fromEntries(
    [...new Set([...Object.keys(fallback), ...Object.keys(primary)])]
      .map((key) => [key, primary[key] || fallback[key] || '']),
  );
}

let pdfJsPromise;
async function pdfJs() {
  globalThis.DOMMatrix ||= DOMMatrix;
  globalThis.ImageData ||= ImageData;
  globalThis.Path2D ||= Path2D;
  pdfJsPromise ||= import('pdfjs-dist/legacy/build/pdf.mjs');
  return pdfJsPromise;
}

async function renderPdfPages(bytes) {
  const pdfjs = await pdfJs();
  const task = pdfjs.getDocument({
    data: new Uint8Array(bytes),
    useSystemFonts: true,
    isEvalSupported: false,
  });
  const document = await task.promise;
  const pages = [];
  for (let pageNumber = 1; pageNumber <= Math.min(document.numPages, 5); pageNumber += 1) {
    const page = await document.getPage(pageNumber);
    const viewport = page.getViewport({ scale: 2 });
    const canvas = createCanvas(Math.ceil(viewport.width), Math.ceil(viewport.height));
    const context = canvas.getContext('2d');
    await page.render({ canvasContext: context, viewport }).promise;
    pages.push(canvas.toBuffer('image/png'));
  }
  await document.destroy();
  return pages;
}

async function extractPdfText(bytes) {
  const pdfjs = await pdfJs();
  const task = pdfjs.getDocument({
    data: new Uint8Array(bytes),
    useSystemFonts: true,
    isEvalSupported: false,
  });
  const document = await task.promise;
  const pages = [];
  for (let pageNumber = 1; pageNumber <= Math.min(document.numPages, 20); pageNumber += 1) {
    const page = await document.getPage(pageNumber);
    const content = await page.getTextContent();
    pages.push(content.items.map((item) => item.str || '').join(' '));
  }
  await document.destroy();
  return pages.join('\n');
}

async function extractPdfFields(bytes) {
  const values = {};
  try {
    const document = await PDFDocument.load(bytes, { ignoreEncryption: true });
    for (const field of document.getForm().getFields()) {
      const name = field.getName();
      if (field instanceof PDFTextField) values[name] = normalizeText(field.getText());
      if (field instanceof PDFCheckBox) values[name] = field.isChecked();
    }
  } catch (_) {
    return {};
  }
  return values;
}

function valuesFromPdfFields(fields, materials, clothingItems) {
  const inventoryNumber = fields.Inventarnummer || '';
  const itemMatch = findItem(inventoryNumber, materials, clothingItems);
  const checkboxValue = [
    ['Nicht_einsatzfaehig', 'Nicht einsatzfähig'],
    ['Nicht einsatzfähig', 'Nicht einsatzfähig'],
    ['Eingeschraenkt', 'Eingeschränkt'],
    [' Eingeschränkt', 'Eingeschränkt'],
    ['Einsatzfaehig', 'Einsatzfähig'],
    [' Einsatzfähig', 'Einsatzfähig'],
  ].filter(([name]) => fields[name] === true);
  const riskValue = [
    ['Gefaehrdung_Hoch', 'Hoch'], [' Hoch', 'Hoch'],
    ['Gefaehrdung_Mittel', 'Mittel'], [' Mittel', 'Mittel'],
    ['Gefaehrdung_Niedrig', 'Niedrig'], ['Niedrig', 'Niedrig'],
  ].find(([name]) => fields[name] === true)?.[1] || 'Keine Angabe';
  return {
    inventoryNumber: itemMatch?.item.inventoryNumber || inventoryNumber,
    description: fields.Beschreibung_des_Mangels || '',
    operationalSafety: checkboxValue.length === 1 ? checkboxValue[0][1] : '',
    contactName: fields.Name || '',
    contactEmail: String(fields['E-Mailadresse'] || '').toLowerCase(),
    contactPhone: fields.Telefonnummer || '',
    cause: fields.Getroffene_Maßnahmen || '',
    riskLevel: riskValue,
    entityType: itemMatch?.entityType || '',
    entityId: itemMatch?.item.id || '',
  };
}

function requiredProblems(values) {
  const problems = [];
  if (!values.inventoryNumber || !values.entityId) problems.push('Inventarnummer konnte keinem Artikel eindeutig zugeordnet werden.');
  if (!normalizeText(values.description)) problems.push('Beschreibung fehlt oder konnte nicht sicher erkannt werden.');
  if (!OPERATIONAL_SAFETY.has(values.operationalSafety)) problems.push('Einsatzbereitschaft fehlt oder konnte nicht sicher erkannt werden.');
  if (!normalizeText(values.contactName)) problems.push('Name der meldenden Person fehlt oder konnte nicht sicher erkannt werden.');
  if (!EMAIL_PATTERN.test(String(values.contactEmail || ''))) problems.push('E-Mail-Adresse der meldenden Person fehlt oder ist ungültig.');
  return problems;
}

function titleFromDescription(description) {
  const normalized = normalizeText(description);
  const sentence = normalized.split(/(?<=[.!?])\s/)[0] || normalized;
  return sentence.slice(0, 160) || 'Mangel aus E-Mail';
}

function publicImport(entry, includeContent = false) {
  return {
    ...entry,
    attachments: entry.attachments.map((attachment) => includeContent ? attachment : ({
      fileName: attachment.fileName,
      mimeType: attachment.mimeType,
      sizeBytes: attachment.sizeBytes,
      role: attachment.role,
    })),
  };
}

function createDefectEmailService({
  defectEmailImports,
  defectManagement,
  defectReports,
  materials,
  clothingItems,
  persistData = async () => {},
  logger = console,
} = {}) {
  let workerPromise;

  async function worker() {
    workerPromise ||= createWorker(
      germanLanguage.code,
      OEM.LSTM_ONLY,
      {
        langPath: germanLanguage.langPath,
        gzip: germanLanguage.gzip,
        cacheMethod: 'none',
        logger: (progress) => {
          if (progress.status === 'recognizing text' && progress.progress === 1) {
            logger.log('Lokale OCR für einen Mängelbericht abgeschlossen.');
          }
        },
      },
      { load_system_dawg: '0', load_freq_dawg: '0' },
    ).then(async (instance) => {
      await instance.setParameters({
        tessedit_pageseg_mode: PSM.SPARSE_TEXT,
        preserve_interword_spaces: '1',
      });
      return instance;
    });
    return workerPromise;
  }

  async function ocrImage(bytes) {
    const normalized = await sharp(bytes)
      .rotate()
      .flatten({ background: '#ffffff' })
      .greyscale()
      .normalize()
      .png()
      .toBuffer();
    const result = await (await worker()).recognize(normalized);
    return normalizeText(result.data.text);
  }

  async function normalizeImage(attachment, type) {
    if (type === 'image/jpeg' || type === 'image/png') {
      return {
        bytes: attachment.content,
        mimeType: type,
        fileName: safeFileName(attachment.filename, type === 'image/png' ? 'bild.png' : 'bild.jpg'),
      };
    }
    const bytes = await sharp(attachment.content)
      .rotate()
      .jpeg({ quality: 88, mozjpeg: true })
      .toBuffer();
    return {
      bytes,
      mimeType: 'image/jpeg',
      fileName: replaceExtension(safeFileName(attachment.filename, 'bild'), 'jpg'),
    };
  }

  async function analyzeAttachments(parsed) {
    const substantive = parsed.attachments.filter((attachment) => {
      const isInline = attachment.contentDisposition === 'inline' || Boolean(attachment.cid);
      return !(isInline && attachment.content.length < 100 * 1024);
    });
    const totalBytes = substantive.reduce((sum, attachment) => sum + attachment.content.length, 0);
    if (totalBytes > MAX_ATTACHMENTS_BYTES) {
      return { problems: ['Die Anhänge überschreiten zusammen 20 MB.'], attachments: [], extracted: {} };
    }

    const pdfs = [];
    const imageCandidates = [];
    const unknown = [];
    for (const attachment of substantive) {
      const type = magicType(attachment.content);
      if (type === 'application/pdf') {
        pdfs.push(attachment);
      } else if (type?.startsWith('image/')) {
        imageCandidates.push({ attachment, type });
      } else {
        unknown.push(safeFileName(attachment.filename, 'unbekannter-anhang'));
      }
    }
    const problems = [];
    if (unknown.length) problems.push(`Nicht unterstützte Anhänge: ${unknown.join(', ')}.`);
    if (pdfs.length > 1) problems.push('Mehr als ein PDF-Mängelbericht wurde angehängt.');
    if (pdfs.some((attachment) => attachment.content.length > MAX_REPORT_BYTES)) {
      problems.push('Der PDF-Mängelbericht überschreitet 10 MB.');
    }

    let extracted = {};
    const reportDocuments = [];
    const images = [];
    let pdfText = '';
    if (pdfs.length === 1 && pdfs[0].content.length <= MAX_REPORT_BYTES) {
      const pdf = pdfs[0];
      const fields = await extractPdfFields(pdf.content);
      const fieldValues = valuesFromPdfFields(fields, materials, clothingItems);
      pdfText = await extractPdfText(pdf.content).catch(() => '');
      let textValues = extractFromText(pdfText, materials, clothingItems);
      extracted = mergeExtracted(fieldValues, textValues);
      if (requiredProblems(extracted).length && reportScore(pdfText) >= 2) {
        const pageTexts = [];
        for (const page of await renderPdfPages(pdf.content)) pageTexts.push(await ocrImage(page));
        textValues = extractFromText(pageTexts.join('\n'), materials, clothingItems);
        extracted = mergeExtracted(extracted, textValues);
      }
      reportDocuments.push({
        fileName: safeFileName(pdf.filename, 'maengelbericht.pdf'),
        mimeType: 'application/pdf',
        sizeBytes: pdf.content.length,
        fileBase64: pdf.content.toString('base64'),
        role: 'report',
      });
    }

    const reportImages = [];
    for (const candidate of imageCandidates) {
      let image;
      try {
        image = await normalizeImage(candidate.attachment, candidate.type);
      } catch (_) {
        problems.push(`${safeFileName(candidate.attachment.filename, 'Bild')} konnte nicht lokal konvertiert werden.`);
        continue;
      }
      if (image.bytes.length > MAX_IMAGE_BYTES) {
        problems.push(`${image.fileName} überschreitet 8 MB.`);
        continue;
      }
      const ocrText = await ocrImage(image.bytes);
      if (reportScore(ocrText) >= 2) {
        reportImages.push({ ...image, ocrText });
      } else {
        images.push({
          fileName: image.fileName,
          mimeType: image.mimeType,
          sizeBytes: image.bytes.length,
          fileBase64: image.bytes.toString('base64'),
          role: 'image',
        });
      }
    }
    if (pdfs.length && reportImages.length) {
      problems.push('Neben dem PDF wurde mindestens ein weiterer Mängelbericht als Bild erkannt.');
    } else if (!pdfs.length && reportImages.length) {
      const imageText = reportImages.map((image) => image.ocrText).join('\n');
      extracted = extractFromText(imageText, materials, clothingItems);
      for (const image of reportImages) {
        reportDocuments.push({
          fileName: image.fileName,
          mimeType: image.mimeType,
          sizeBytes: image.bytes.length,
          fileBase64: image.bytes.toString('base64'),
          role: 'report',
        });
      }
    }
    if (!reportDocuments.length) problems.push('Kein Mängelbericht wurde in den Anhängen erkannt.');
    if (images.length > MAX_IMAGES) problems.push(`Es wurden mehr als ${MAX_IMAGES} Schadensbilder angehängt.`);
    return {
      problems,
      extracted,
      attachments: [...reportDocuments, ...images.slice(0, MAX_IMAGES)],
    };
  }

  function valuesForEntry(entry, overrides = {}) {
    const values = { ...entry.extractedData, ...overrides };
    const itemMatch = findItem(values.inventoryNumber, materials, clothingItems);
    if (itemMatch) {
      values.inventoryNumber = itemMatch.item.inventoryNumber;
      values.entityType = itemMatch.entityType;
      values.entityId = itemMatch.item.id;
    } else {
      values.entityType = '';
      values.entityId = '';
    }
    values.description = normalizeText(values.description);
    values.contactName = normalizeText(values.contactName);
    values.contactEmail = String(values.contactEmail || '').trim().toLowerCase();
    values.operationalSafety = normalizeText(values.operationalSafety);
    return values;
  }

  async function processEntry(entry, overrides = {}, actor) {
    if (entry.status !== 'pending') return { error: 'Diese E-Mail wurde bereits abgeschlossen.' };
    const values = valuesForEntry(entry, overrides);
    const problems = requiredProblems(values);
    if (problems.length) return { error: problems.join(' '), problems };
    if (actor && !defectManagement.canScope(actor, values.entityType)) {
      return { error: 'Für den erkannten Bereich fehlt die Berechtigung.' };
    }
    const result = defectManagement.createFromEmail({
      body: {
        entityType: values.entityType,
        entityId: values.entityId,
        affectedQuantity: 1,
        title: titleFromDescription(values.description),
        description: values.description,
        priority: 'Normal',
        operationalSafety: values.operationalSafety,
        riskLevel: values.riskLevel || 'Keine Angabe',
        cause: values.cause || '',
        contactName: values.contactName,
        contactEmail: values.contactEmail,
        contactPhone: values.contactPhone || '',
      },
      source: {
        importId: entry.id,
        messageId: entry.messageId,
        mailbox: entry.mailbox,
        uid: entry.processedUid || entry.uid,
        uidValidity: entry.processedUidValidity || entry.uidValidity,
        processedMailbox: entry.processedMailbox || null,
        sender: entry.sender,
      },
      reportDocuments: entry.attachments.filter((attachment) => attachment.role === 'report'),
      images: entry.attachments.filter((attachment) => attachment.role === 'image'),
      emailComment: entry.emailText,
      actor: actor || undefined,
    });
    if (result.error) return result;
    entry.status = 'processed';
    entry.processedAt = new Date().toISOString();
    entry.processedBy = actor?.username || 'E-Mail-Eingang';
    entry.defectId = result.report.id;
    entry.extractedData = values;
    entry.attachments = entry.attachments.map(({ fileBase64, ...attachment }) => attachment);
    await persistData();
    return result;
  }

  async function ingestSource(source, sourceInfo = {}) {
    if (!Buffer.isBuffer(source)) source = Buffer.from(source);
    if (source.length > MAX_MESSAGE_BYTES) {
      throw new Error('Die E-Mail überschreitet die maximalen 25 MB.');
    }
    const parsed = await simpleParser(source, {
      skipHtmlToText: false,
      skipImageLinks: true,
      maxHtmlLengthToParse: 2 * 1024 * 1024,
    });
    const messageId = normalizeText(
      parsed.messageId
      || sourceInfo.messageId
      || `sha256:${createHash('sha256').update(source).digest('hex')}`,
    );
    const duplicate = defectEmailImports.find((entry) =>
      messageId && entry.messageId === messageId);
    if (duplicate) return { duplicate: true, entry: duplicate };
    const analysis = await analyzeAttachments(parsed);
    const entry = {
      id: `defect-email-${randomUUID()}`,
      messageId: messageId || null,
      sender: parsed.from?.value?.[0]?.address?.toLowerCase() || '',
      senderName: normalizeText(parsed.from?.value?.[0]?.name || ''),
      subject: normalizeText(parsed.subject || ''),
      emailText: normalizeText(parsed.text || ''),
      receivedAt: parsed.date?.toISOString?.() || new Date().toISOString(),
      mailbox: sourceInfo.mailbox || null,
      uid: sourceInfo.uid || null,
      uidValidity: sourceInfo.uidValidity || null,
      processedMailbox: sourceInfo.processedMailbox || null,
      processedUid: sourceInfo.processedUid || null,
      processedUidValidity: sourceInfo.processedUidValidity || null,
      status: 'pending',
      problems: [...analysis.problems],
      extractedData: analysis.extracted,
      attachments: analysis.attachments,
      createdAt: new Date().toISOString(),
    };
    entry.problems.push(...requiredProblems(valuesForEntry(entry)));
    entry.problems = [...new Set(entry.problems)];
    defectEmailImports.push(entry);
    let result = { entry };
    if (entry.problems.length === 0) result = await processEntry(entry);
    await persistData();
    return { ...result, entry };
  }

  async function recordFailure(sourceInfo, error) {
    const duplicate = defectEmailImports.find((entry) =>
      sourceInfo.messageId && entry.messageId === sourceInfo.messageId);
    if (duplicate) return duplicate;
    const entry = {
      id: `defect-email-${randomUUID()}`,
      messageId: sourceInfo.messageId || null,
      sender: '',
      senderName: '',
      subject: '',
      emailText: '',
      receivedAt: new Date().toISOString(),
      mailbox: sourceInfo.mailbox || null,
      uid: sourceInfo.uid || null,
      uidValidity: sourceInfo.uidValidity || null,
      processedMailbox: sourceInfo.processedMailbox || null,
      processedUid: null,
      processedUidValidity: null,
      status: 'pending',
      problems: [normalizeText(error?.message || error || 'E-Mail konnte nicht verarbeitet werden.')],
      extractedData: {},
      attachments: [],
      createdAt: new Date().toISOString(),
    };
    defectEmailImports.push(entry);
    await persistData();
    return entry;
  }

  async function updateMoved(entry, { mailbox, uid, uidValidity }) {
    entry.processedMailbox = mailbox;
    entry.processedUid = uid || null;
    entry.processedUidValidity = uidValidity || null;
    if (entry.defectId) {
      const report = defectReports.find((candidate) => candidate.id === entry.defectId);
      if (report?.emailSource) {
        report.emailSource.processedMailbox = mailbox;
        report.emailSource.uid = uid || report.emailSource.uid;
        report.emailSource.uidValidity = uidValidity || report.emailSource.uidValidity;
      }
    }
    await persistData();
  }

  async function discard(entry, reason, actor) {
    if (entry.status !== 'pending') return { error: 'Diese E-Mail wurde bereits abgeschlossen.' };
    entry.status = 'discarded';
    entry.discardedAt = new Date().toISOString();
    entry.discardedBy = actor.username;
    entry.discardReason = normalizeText(reason) || 'Manuell verworfen';
    entry.attachments = entry.attachments.map(({ fileBase64, ...attachment }) => attachment);
    await persistData();
    return { entry };
  }

  async function stop() {
    if (!workerPromise) return;
    const instance = await workerPromise;
    workerPromise = null;
    await instance.terminate();
  }

  async function applyRetentionPolicy(referenceDate = new Date()) {
    const cutoffDate = new Date(referenceDate);
    cutoffDate.setUTCFullYear(cutoffDate.getUTCFullYear() - 2);
    const cutoff = cutoffDate.getTime();
    for (let index = defectEmailImports.length - 1; index >= 0; index -= 1) {
      const entry = defectEmailImports[index];
      const processedDefectExists = entry.status === 'processed'
        && defectReports.some((report) => report.id === entry.defectId);
      const discardedAt = Date.parse(entry.discardedAt || '');
      if ((entry.status === 'processed' && !processedDefectExists)
        || (entry.status === 'discarded' && Number.isFinite(discardedAt) && discardedAt <= cutoff)) {
        defectEmailImports.splice(index, 1);
      }
    }
  }

  return {
    applyRetentionPolicy,
    discard,
    ingestSource,
    list: () => defectEmailImports.slice().reverse().map((entry) => publicImport(entry)),
    processEntry,
    publicImport,
    recordFailure,
    stop,
    updateMoved,
    valuesForEntry,
  };
}

function registerDefectEmailRoutes({
  app,
  authMiddleware,
  requirePermission,
  defectEmailImports,
  defectEmailService,
  defectManagement,
  materials,
  clothingItems,
}) {
  function canAccess(req, entry) {
    const entityType = entry.extractedData?.entityType;
    if (entityType) return defectManagement.canScope(req.user, entityType);
    return req.user?.roles?.some((role) => role === 'Admin' || role === 'Vorsitz');
  }

  function findEntry(req, res) {
    const entry = defectEmailImports.find((candidate) => candidate.id === req.params.id);
    if (!entry || !canAccess(req, entry)) {
      res.status(404).json({ error: 'E-Mail-Meldung nicht gefunden.' });
      return null;
    }
    return entry;
  }

  app.get('/api/defect-email-imports', authMiddleware, requirePermission('defects.read'), (_req, res) => {
    return res.json(defectEmailService.list().filter((entry) => canAccess(_req, entry)));
  });

  app.get('/api/defect-report-items', authMiddleware, requirePermission('defects.read'), (req, res) => {
    const values = [
      ...materials.map((item) => ({ item, entityType: 'MaterialItem' })),
      ...clothingItems.map((item) => ({ item, entityType: 'ClothingItem' })),
    ].filter(({ entityType }) => defectManagement.canScope(req.user, entityType))
      .map(({ item, entityType }) => ({
        id: item.id,
        entityType,
        inventoryNumber: item.inventoryNumber,
        name: item.name,
        quantity: entityType === 'MaterialItem' ? Number(item.quantity || 1) : 1,
        status: item.status,
      }));
    return res.json(values);
  });

  app.get('/api/defect-email-imports/:id', authMiddleware, requirePermission('defects.read'), (req, res) => {
    const entry = findEntry(req, res);
    if (!entry) return;
    return res.json(defectEmailService.publicImport(entry, true));
  });

  app.post('/api/defect-email-imports/:id/process',
    authMiddleware, requirePermission('defects.report'), async (req, res) => {
      const entry = findEntry(req, res);
      if (!entry) return;
      const result = await defectEmailService.processEntry(entry, req.body, req.user);
      if (result.error) return res.status(400).json({ error: result.error, problems: result.problems });
      return res.status(201).json(result.report);
    });

  app.post('/api/defect-email-imports/:id/discard',
    authMiddleware, requirePermission('defects.edit'), async (req, res) => {
      const entry = findEntry(req, res);
      if (!entry) return;
      const result = await defectEmailService.discard(entry, req.body.reason, req.user);
      if (result.error) return res.status(409).json({ error: result.error });
      return res.json(defectEmailService.publicImport(result.entry));
    });

  app.get('/api/defect-report-template', authMiddleware, requirePermission('defects.read'), async (req, res) => {
    let inventoryNumber = '';
    if (req.query.entityId) {
      const candidates = [
        ...materials.map((item) => ({ item, entityType: 'MaterialItem' })),
        ...clothingItems.map((item) => ({ item, entityType: 'ClothingItem' })),
      ];
      const match = candidates.find(({ item, entityType }) =>
        item.id === req.query.entityId
        && (!req.query.entityType || entityType === req.query.entityType));
      if (!match) return res.status(404).json({ error: 'Artikel für die Vorbefüllung nicht gefunden.' });
      if (!defectManagement.canScope(req.user, match.entityType)) {
        return res.status(403).json({ error: 'Für diesen Bereich fehlt die Berechtigung.' });
      }
      inventoryNumber = match.item.inventoryNumber;
    }
    const buffer = await generateDefectReportPdf({
      inventoryNumber,
      contactName: inventoryNumber ? req.user.name || req.user.username : '',
      contactEmail: inventoryNumber ? req.user.email : '',
    });
    return res.json({
      fileName: inventoryNumber
        ? `maengelbericht-${inventoryNumber}.pdf`
        : 'maengelbericht-vorlage.pdf',
      mimeType: 'application/pdf',
      fileBase64: buffer.toString('base64'),
    });
  });

}

module.exports = {
  MAX_ATTACHMENTS_BYTES,
  MAX_MESSAGE_BYTES,
  createDefectEmailService,
  extractFromText,
  magicType,
  registerDefectEmailRoutes,
  renderPdfPages,
  reportScore,
  requiredProblems,
};
