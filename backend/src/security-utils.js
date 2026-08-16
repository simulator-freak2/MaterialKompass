const ZIP_CENTRAL_DIRECTORY_SIGNATURE = 0x02014b50;
const ZIP_END_SIGNATURE = 0x06054b50;

function inspectZipArchive(bytes, {
  maxEntries = 2_000,
  maxUncompressedBytes = 50 * 1024 * 1024,
} = {}) {
  if (!Buffer.isBuffer(bytes) || bytes.length < 22) {
    return { error: 'Die Datei enthält kein gültiges ZIP-Verzeichnis.' };
  }
  let endOffset = -1;
  const searchStart = Math.max(0, bytes.length - 65_557);
  for (let offset = bytes.length - 22; offset >= searchStart; offset -= 1) {
    if (bytes.readUInt32LE(offset) === ZIP_END_SIGNATURE) {
      endOffset = offset;
      break;
    }
  }
  if (endOffset < 0) return { error: 'Die Datei enthält kein gültiges ZIP-Verzeichnis.' };
  const diskNumber = bytes.readUInt16LE(endOffset + 4);
  const directoryDisk = bytes.readUInt16LE(endOffset + 6);
  const diskEntries = bytes.readUInt16LE(endOffset + 8);
  const totalEntries = bytes.readUInt16LE(endOffset + 10);
  const directorySize = bytes.readUInt32LE(endOffset + 12);
  const directoryOffset = bytes.readUInt32LE(endOffset + 16);
  if (diskNumber !== 0 || directoryDisk !== 0 || diskEntries !== totalEntries
    || totalEntries === 0xffff || directorySize === 0xffffffff || directoryOffset === 0xffffffff) {
    return { error: 'Mehrteilige Archive und ZIP64-Dateien werden nicht unterstützt.' };
  }
  if (totalEntries === 0 || totalEntries > maxEntries
    || directoryOffset + directorySize > endOffset) {
    return { error: 'Das Archiv ist ungültig oder enthält zu viele Dateien.' };
  }
  let entries = 0;
  let uncompressedBytes = 0;
  let offset = directoryOffset;
  while (offset < directoryOffset + directorySize && entries < totalEntries) {
    if (offset + 46 > endOffset || bytes.readUInt32LE(offset) !== ZIP_CENTRAL_DIRECTORY_SIGNATURE) {
      return { error: 'Das ZIP-Verzeichnis ist beschädigt.' };
    }
    const flags = bytes.readUInt16LE(offset + 8);
    const compressionMethod = bytes.readUInt16LE(offset + 10);
    const compressedSize = bytes.readUInt32LE(offset + 20);
    const uncompressedSize = bytes.readUInt32LE(offset + 24);
    const fileNameLength = bytes.readUInt16LE(offset + 28);
    const extraLength = bytes.readUInt16LE(offset + 30);
    const commentLength = bytes.readUInt16LE(offset + 32);
    if ((flags & 0x1) !== 0) return { error: 'Verschlüsselte ZIP-Dateien werden nicht unterstützt.' };
    if (![0, 8].includes(compressionMethod)) return { error: 'Das Archiv verwendet ein nicht unterstütztes Kompressionsverfahren.' };
    if (compressedSize === 0xffffffff || uncompressedSize === 0xffffffff) {
      return { error: 'ZIP64-Dateien werden aus Sicherheitsgründen nicht unterstützt.' };
    }
    entries += 1;
    uncompressedBytes += uncompressedSize;
    if (entries > maxEntries || uncompressedBytes > maxUncompressedBytes) {
      return { error: 'Das Archiv ist nach dem Entpacken zu groß oder enthält zu viele Dateien.' };
    }
    if (uncompressedSize > 1024 * 1024 && compressedSize > 0
      && uncompressedSize / compressedSize > 200) {
      return { error: 'Das Archiv weist ein unsicheres Kompressionsverhältnis auf.' };
    }
    offset += 46 + fileNameLength + extraLength + commentLength;
  }
  if (entries !== totalEntries || offset !== directoryOffset + directorySize) {
    return { error: 'Das ZIP-Verzeichnis ist unvollständig oder beschädigt.' };
  }
  return { entries, uncompressedBytes };
}

function neutralizeSpreadsheetCell(value) {
  const text = String(value ?? '');
  return /^[\t\r\n ]*[=+\-@]/.test(text) ? `'${text}` : text;
}

function validBase64(value) {
  return typeof value === 'string'
    && value.length % 4 === 0
    && /^[A-Za-z0-9+/]*={0,2}$/.test(value);
}

function fileMagic(bytes) {
  if (bytes.subarray(0, 5).toString('ascii') === '%PDF-') return 'pdf';
  if (bytes.length >= 8
    && bytes.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))) {
    return 'png';
  }
  if (bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) {
    return 'jpeg';
  }
  if (bytes.length >= 4 && bytes.readUInt32LE(0) === 0x04034b50) return 'zip';
  return null;
}

module.exports = {
  fileMagic,
  inspectZipArchive,
  neutralizeSpreadsheetCell,
  validBase64,
};
