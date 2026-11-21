const crypto = require('node:crypto');
const fs = require('node:fs');
const fsp = require('node:fs/promises');
const path = require('node:path');
const zlib = require('node:zlib');
const { pipeline } = require('node:stream/promises');
const { Writable } = require('node:stream');
const { randomUUID } = require('node:crypto');
const { isPlatformAdministration, PLATFORM_ORGANIZATION_ID, PLATFORM_UNIT_ID } = require('./platform-administration');
const { backupDocument, validatedBackup, applyFullRestore, BACKUP_SCHEMA_VERSION } = require('./data-backup');
const { rawCollection } = require('./tenancy');

// Server-side platform backups are complete, authenticated-encrypted snapshots
// in a dedicated volume. The weekly check proves that the backups can be read,
// decrypted and validated for a restore, and that the MariaDB dumps are fresh,
// intact and complete.
const FILE_MAGIC = Buffer.from('MKPB1\n', 'utf8');
const KEY_PURPOSE = 'materialkompass:platform-backup:v1';
const BACKUP_ID = /^pb-\d{8}T\d{6}Z-[a-f0-9]{8}$/;
const CHECK_ID = /^bc-\d{8}T\d{6}Z-[a-f0-9]{8}$/;
const DUMP_NAME = /^materialkompass-v2-\d{8}T\d{6}Z\.sql\.gz$/;
const REASONS = new Set(['manual', 'scheduled', 'pre-restore']);
const CHECKS_FILE = 'backup-checks.json';
const MAX_CHECKS = 60;
const MAX_ACKNOWLEDGEMENTS_PER_CHECK = 200;
// Below V8's maximum string length so JSON.parse never aborts the process.
const MAX_DECOMPRESSED_BYTES = 384 * 1024 * 1024;
const MAX_USER_IDS = 100_000;
const MAX_BACKUP_FILE_BYTES = 512 * 1024 * 1024;
const DAY_MS = 24 * 60 * 60 * 1000;
const DEFAULTS = Object.freeze({
  retentionDays: 30,
  minimumKept: 3,
  maximumBackups: 50,
  manualIntervalMs: 10 * 60 * 1000,
  manualCheckIntervalMs: 5 * 60 * 1000,
  platformBackupMaxAgeDays: 8,
  dumpMaxAgeHours: 26,
  // Monday 03:30 UTC: after the daily MariaDB dump at 02:00 UTC.
  scheduleWeekday: 1,
  scheduleMinutesUtc: 3 * 60 + 30,
  schedulerIntervalMs: 10 * 60 * 1000,
});
const STATUS_RANK = { ok: 0, warning: 1, error: 2 };
const REQUIRED_DUMP_MARKERS = Object.freeze([
  'CREATE TABLE `users`',
  'CREATE TABLE `application_collections`',
  'CREATE TABLE `identity_protection_state`',
  '-- Dump completed',
]);

function publicMetadata(entry) {
  if (!entry) return entry;
  const { userIds: _userIds, ...visible } = entry;
  return visible;
}

function httpError(status, message) {
  return Object.assign(new Error(message), { status, expose: true });
}

function compactTimestamp(date) {
  return date.toISOString().replace(/[-:]/g, '').replace(/\.\d{3}Z$/, 'Z');
}

function positiveInteger(value, fallback) {
  const parsed = Number.parseInt(value, 10);
  return Number.isInteger(parsed) && parsed > 0 ? parsed : fallback;
}

function metadataAad(metadata) {
  return Buffer.from(JSON.stringify([
    'MaterialKompass platform backup', 1, metadata.id, metadata.createdAt, metadata.reason,
    metadata.applicationVersion, metadata.schemaVersion, metadata.recordCount,
    metadata.createdByUserId || null,
  ]), 'utf8');
}

function worstStatus(items) {
  return items.reduce((worst, item) =>
    (STATUS_RANK[item.status] > STATUS_RANK[worst] ? item.status : worst), 'ok');
}

// Most recent scheduled slot (weekday + minute of day, UTC) at or before now.
function scheduledSlot(now, weekday, minutesUtc) {
  const slot = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate(),
    Math.floor(minutesUtc / 60), minutesUtc % 60));
  const offset = (slot.getUTCDay() - weekday + 7) % 7;
  slot.setUTCDate(slot.getUTCDate() - offset);
  if (slot > now) slot.setUTCDate(slot.getUTCDate() - 7);
  return slot;
}

async function writeFileAtomic(filePath, content) {
  const temporary = path.join(path.dirname(filePath), `.${path.basename(filePath)}.${randomUUID()}.tmp`);
  let handle;
  try {
    handle = await fsp.open(temporary, 'wx', 0o600);
    await handle.writeFile(content);
    await handle.sync();
    await handle.close();
    handle = undefined;
    await fsp.rename(temporary, filePath);
  } catch (error) {
    if (handle) await handle.close().catch(() => {});
    await fsp.rm(temporary, { force: true }).catch(() => {});
    throw error;
  }
}

async function readRegularFile(filePath, maximumBytes) {
  const handle = await fsp.open(filePath, fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW || 0));
  try {
    const stats = await handle.stat();
    if (!stats.isFile() || stats.size > maximumBytes) throw new Error('Die Datei ist ungültig oder zu groß.');
    return await handle.readFile();
  } finally {
    await handle.close();
  }
}

async function sha256File(filePath) {
  const hash = crypto.createHash('sha256');
  await pipeline(fs.createReadStream(filePath, { flags: fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW || 0) }), hash);
  return hash.digest('hex');
}

function createPlatformBackupService({
  directory,
  dumpDirectory = null,
  identityProtection,
  appData,
  collectionNames,
  applicationVersion,
  dataStore,
  persistData,
  now = () => new Date(),
  options = {},
}) {
  const settings = { ...DEFAULTS, ...options };
  const resolvedDirectory = directory ? path.resolve(directory) : null;
  const resolvedDumpDirectory = dumpDirectory ? path.resolve(dumpDirectory) : null;
  let key = null;
  let running = null;
  let lastManualCreate = 0;
  let lastManualCheck = 0;
  let timer = null;

  function assertConfigured() {
    if (!resolvedDirectory) {
      throw httpError(503, 'Serverseitige Plattformsicherungen sind nicht konfiguriert (PLATFORM_BACKUP_DIR).');
    }
  }

  function encryptionKey() {
    if (!key) key = identityProtection.deriveApplicationKey(KEY_PURPOSE);
    return key;
  }

  async function ensureDirectory() {
    assertConfigured();
    await fsp.mkdir(resolvedDirectory, { recursive: true, mode: 0o700 });
    const stats = await fsp.lstat(resolvedDirectory);
    if (!stats.isDirectory()) throw new Error('PLATFORM_BACKUP_DIR ist kein Verzeichnis.');
  }

  function filePaths(id) {
    if (!BACKUP_ID.test(String(id || ''))) throw httpError(404, 'Sicherung nicht gefunden.');
    return {
      data: path.join(resolvedDirectory, `${id}.mkbackup`),
      metadata: path.join(resolvedDirectory, `${id}.json`),
    };
  }

  // Serialises create, check and restore; concurrent operations would race
  // on the same live arrays and on retention pruning.
  async function exclusive(label, operation) {
    if (running) throw httpError(409, `Es läuft bereits eine Sicherungsaktion (${running}).`);
    running = label;
    try {
      return await operation();
    } finally {
      running = null;
    }
  }

  function normalizeMetadata(value) {
    if (!value || typeof value !== 'object' || !BACKUP_ID.test(String(value.id || ''))
      || !REASONS.has(value.reason) || Number.isNaN(Date.parse(value.createdAt))
      || !/^[a-f0-9]{64}$/.test(String(value.sha256 || ''))) return null;
    return {
      id: value.id,
      createdAt: new Date(value.createdAt).toISOString(),
      reason: value.reason,
      createdByUserId: typeof value.createdByUserId === 'string' ? value.createdByUserId.slice(0, 128) : null,
      applicationVersion: String(value.applicationVersion || '').slice(0, 64),
      schemaVersion: Number(value.schemaVersion) || null,
      recordCount: Number.isSafeInteger(value.recordCount) ? value.recordCount : null,
      sizeBytes: Number.isSafeInteger(value.sizeBytes) ? value.sizeBytes : null,
      sha256: value.sha256,
      restoredFromId: BACKUP_ID.test(String(value.restoredFromId || '')) ? value.restoredFromId : null,
      userIds: Array.isArray(value.userIds)
        ? value.userIds.slice(0, MAX_USER_IDS).filter((entry) => typeof entry === 'string' && entry.length <= 128)
        : [],
    };
  }

  async function list() {
    if (!resolvedDirectory) return [];
    let names;
    try {
      if (!(await fsp.lstat(resolvedDirectory)).isDirectory()) throw new Error('PLATFORM_BACKUP_DIR ist kein Verzeichnis.');
      names = await fsp.readdir(resolvedDirectory);
    } catch (error) {
      if (error.code === 'ENOENT') return [];
      throw error;
    }
    const entries = [];
    for (const name of names) {
      const id = name.endsWith('.json') ? name.slice(0, -5) : null;
      if (!id || !BACKUP_ID.test(id)) continue;
      try {
        const metadata = normalizeMetadata(JSON.parse(
          (await readRegularFile(path.join(resolvedDirectory, name), 64 * 1024)).toString('utf8')));
        if (metadata && metadata.id === id) entries.push(metadata);
      } catch (_) {
        // Unreadable metadata is reported by the integrity check, not listed.
      }
    }
    return entries.sort((left, right) => right.createdAt.localeCompare(left.createdAt));
  }

  async function prune() {
    const entries = await list();
    const cutoff = now().getTime() - settings.retentionDays * DAY_MS;
    const removed = [];
    for (const [index, entry] of entries.entries()) {
      if (index < settings.minimumKept || Date.parse(entry.createdAt) >= cutoff) continue;
      const paths = filePaths(entry.id);
      await fsp.rm(paths.data, { force: true });
      await fsp.rm(paths.metadata, { force: true });
      removed.push(entry.id);
    }
    return removed;
  }

  async function createUnlocked({ reason, actorUserId = null, restoredFromId = null }) {
    if (!REASONS.has(reason)) throw httpError(400, 'Ungültiger Sicherungsanlass.');
    await ensureDirectory();
    await prune();
    if ((await list()).length >= settings.maximumBackups) {
      throw httpError(409, `Es sind bereits ${settings.maximumBackups} Sicherungen vorhanden. Ältere Sicherungen laufen nach ${settings.retentionDays} Tagen ab.`);
    }
    const createdAt = now();
    const id = `pb-${compactTimestamp(createdAt)}-${crypto.randomBytes(4).toString('hex')}`;
    const document = await backupDocument(appData, collectionNames, applicationVersion, identityProtection);
    const recordCount = document.sections.reduce((sum, section) => sum + section.records.length, 0);
    const metadata = {
      id,
      createdAt: createdAt.toISOString(),
      reason,
      createdByUserId: actorUserId,
      applicationVersion,
      schemaVersion: document.schemaVersion,
      recordCount,
      restoredFromId,
    };
    // Account IDs only (no identities): needed to keep identity keys of
    // accounts that exist in a retained backup when a restore removes them.
    const userIds = (document.sections.find((section) => section.name === 'users')?.records || [])
      .map((user) => String(user.id));
    const compressed = zlib.gzipSync(Buffer.from(JSON.stringify(document), 'utf8'), { level: 6 });
    const iv = crypto.randomBytes(12);
    const cipher = crypto.createCipheriv('aes-256-gcm', encryptionKey(), iv);
    cipher.setAAD(metadataAad(metadata));
    const ciphertext = Buffer.concat([cipher.update(compressed), cipher.final()]);
    const content = Buffer.concat([FILE_MAGIC, iv, cipher.getAuthTag(), ciphertext]);
    const sha256 = crypto.createHash('sha256').update(content).digest('hex');
    const paths = filePaths(id);
    await writeFileAtomic(paths.data, content);
    const stored = { ...metadata, sizeBytes: content.length, sha256, userIds };
    try {
      await writeFileAtomic(paths.metadata, `${JSON.stringify(stored, null, 2)}\n`);
    } catch (error) {
      await fsp.rm(paths.data, { force: true }).catch(() => {});
      throw error;
    }
    return normalizeMetadata(stored);
  }

  // Reads, authenticates and decrypts a stored backup. Throws on any
  // corruption: checksum, authentication tag, compression or JSON format.
  async function readDocument(id) {
    assertConfigured();
    const paths = filePaths(id);
    let metadata;
    try {
      metadata = normalizeMetadata(JSON.parse((await readRegularFile(paths.metadata, 64 * 1024)).toString('utf8')));
    } catch (error) {
      if (error.code === 'ENOENT') throw httpError(404, 'Sicherung nicht gefunden.');
      throw httpError(422, 'Die Metadaten der Sicherung sind beschädigt.');
    }
    if (!metadata || metadata.id !== id) throw httpError(422, 'Die Metadaten der Sicherung sind beschädigt.');
    let content;
    try {
      content = await readRegularFile(paths.data, MAX_BACKUP_FILE_BYTES);
    } catch (error) {
      if (error.code === 'ENOENT') throw httpError(422, 'Die Sicherungsdatei fehlt.');
      throw httpError(422, 'Die Sicherungsdatei ist nicht lesbar.');
    }
    if (crypto.createHash('sha256').update(content).digest('hex') !== metadata.sha256) {
      throw httpError(422, 'Die SHA-256-Prüfsumme der Sicherung stimmt nicht.');
    }
    const headerLength = FILE_MAGIC.length + 12 + 16;
    if (content.length <= headerLength || !content.subarray(0, FILE_MAGIC.length).equals(FILE_MAGIC)) {
      throw httpError(422, 'Die Sicherungsdatei hat ein unbekanntes Format.');
    }
    let compressed;
    try {
      const decipher = crypto.createDecipheriv('aes-256-gcm', encryptionKey(),
        content.subarray(FILE_MAGIC.length, FILE_MAGIC.length + 12));
      decipher.setAAD(metadataAad(metadata));
      decipher.setAuthTag(content.subarray(FILE_MAGIC.length + 12, headerLength));
      compressed = Buffer.concat([decipher.update(content.subarray(headerLength)), decipher.final()]);
    } catch (_) {
      throw httpError(422, 'Die Sicherung konnte nicht authentifiziert werden (falscher Schlüssel oder Manipulation).');
    }
    let document;
    try {
      document = JSON.parse(zlib.gunzipSync(compressed, { maxOutputLength: MAX_DECOMPRESSED_BYTES }).toString('utf8'));
    } catch (_) {
      throw httpError(422, 'Der Inhalt der Sicherung ist beschädigt.');
    }
    return { metadata, document };
  }

  async function verifyBackup(id, { fullValidation }) {
    const { metadata, document } = await readDocument(id);
    if (!fullValidation) return { metadata };
    const data = await validatedBackup(document, collectionNames, identityProtection, { dryRun: true });
    return {
      metadata,
      users: data.users.length,
      organizations: data.organizations.length,
      records: Object.values(data).reduce((sum, values) => sum + values.length, 0),
    };
  }

  async function newestDump() {
    const names = await fsp.readdir(resolvedDumpDirectory);
    const dumps = names.filter((name) => DUMP_NAME.test(name)).sort().reverse();
    return { name: dumps[0] || null, count: dumps.length };
  }

  // Streams the newest MariaDB dump once: SHA-256 against the sidecar,
  // complete gzip decoding and presence of the essential schema markers.
  async function checkDatabaseDump() {
    if (!resolvedDumpDirectory) {
      return [{ key: 'database-dump', label: 'MariaDB-Tagessicherung', status: 'warning',
        detail: 'Kein Dump-Verzeichnis konfiguriert (DATABASE_DUMP_DIR); die Tagessicherungen wurden nicht geprüft.' }];
    }
    const items = [];
    let dump;
    try {
      dump = await newestDump();
    } catch (_) {
      return [{ key: 'database-dump', label: 'MariaDB-Tagessicherung', status: 'error',
        detail: 'Das Dump-Verzeichnis ist nicht lesbar.' }];
    }
    if (!dump.name) {
      return [{ key: 'database-dump', label: 'MariaDB-Tagessicherung', status: 'error',
        detail: 'Es wurde keine identitätsgeschützte MariaDB-Sicherung gefunden.' }];
    }
    const dumpPath = path.join(resolvedDumpDirectory, dump.name);
    const match = /^materialkompass-v2-(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z/.exec(dump.name);
    const createdAt = new Date(Date.UTC(+match[1], +match[2] - 1, +match[3], +match[4], +match[5], +match[6]));
    const ageHours = (now().getTime() - createdAt.getTime()) / (60 * 60 * 1000);
    items.push({ key: 'database-dump-age', label: 'Aktualität der MariaDB-Tagessicherung',
      status: ageHours <= settings.dumpMaxAgeHours ? 'ok' : 'error',
      detail: `Neueste Sicherung ${dump.name} vom ${createdAt.toISOString()} (${Math.max(0, Math.round(ageHours))} h alt, ${dump.count} vorhanden).` });
    try {
      const expectedLine = (await readRegularFile(`${dumpPath}.sha256`, 4096)).toString('utf8').trim();
      const [expected, fileName] = expectedLine.split(/\s+\*?/);
      const actual = await sha256File(dumpPath);
      const valid = /^[a-f0-9]{64}$/.test(expected) && fileName === dump.name && actual === expected;
      items.push({ key: 'database-dump-checksum', label: 'Prüfsumme der MariaDB-Tagessicherung',
        status: valid ? 'ok' : 'error',
        detail: valid ? 'SHA-256 stimmt mit der Prüfsummendatei überein.' : 'SHA-256 stimmt nicht mit der Prüfsummendatei überein.' });
    } catch (_) {
      items.push({ key: 'database-dump-checksum', label: 'Prüfsumme der MariaDB-Tagessicherung',
        status: 'error', detail: 'Dump oder Prüfsummendatei ist nicht lesbar.' });
      return items;
    }
    try {
      const found = new Set();
      const overlap = Math.max(...REQUIRED_DUMP_MARKERS.map((marker) => marker.length));
      let tail = '';
      let bytes = 0;
      await pipeline(
        fs.createReadStream(dumpPath, { flags: fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW || 0) }),
        zlib.createGunzip(),
        new Writable({
          write(chunk, _encoding, callback) {
            bytes += chunk.length;
            const text = tail + chunk.toString('latin1');
            for (const marker of REQUIRED_DUMP_MARKERS) if (text.includes(marker)) found.add(marker);
            tail = text.slice(-overlap);
            callback();
          },
        }),
      );
      const missing = REQUIRED_DUMP_MARKERS.filter((marker) => !found.has(marker));
      items.push({ key: 'database-dump-content', label: 'Lesbarkeit und Vollständigkeit des MariaDB-Dumps',
        status: missing.length === 0 ? 'ok' : 'error',
        detail: missing.length === 0
          ? `Vollständig entpackt (${Math.round(bytes / 1024)} KiB SQL), alle Kerntabellen und Abschlussmarke vorhanden.`
          : `Es fehlen erwartete Inhalte: ${missing.join(', ')}.` });
    } catch (_) {
      items.push({ key: 'database-dump-content', label: 'Lesbarkeit und Vollständigkeit des MariaDB-Dumps',
        status: 'error', detail: 'Der Dump konnte nicht vollständig entpackt werden.' });
    }
    return items;
  }

  async function readChecks() {
    if (!resolvedDirectory) return [];
    try {
      const document = JSON.parse((await readRegularFile(path.join(resolvedDirectory, CHECKS_FILE), 4 * 1024 * 1024)).toString('utf8'));
      return Array.isArray(document?.checks)
        ? document.checks.filter((entry) => CHECK_ID.test(String(entry?.id || ''))) : [];
    } catch (error) {
      if (error.code === 'ENOENT') return [];
      console.error('Backup-Prüfprotokoll ist nicht lesbar:', error.message);
      return [];
    }
  }

  // Read-modify-write of the check log is serialised so an acknowledgement
  // cannot be lost while a check result is being appended.
  let checksQueue = Promise.resolve();
  function updateChecks(mutator) {
    const next = checksQueue.then(async () => {
      const checks = await readChecks();
      if (await mutator(checks) !== false) await writeChecks(checks);
    });
    checksQueue = next.catch(() => {});
    return next;
  }

  async function writeChecks(checks) {
    await ensureDirectory();
    await writeFileAtomic(path.join(resolvedDirectory, CHECKS_FILE),
      `${JSON.stringify({ schemaVersion: 1, checks: checks.slice(-MAX_CHECKS) }, null, 2)}\n`);
  }

  async function runCheckUnlocked({ kind, actorUserId = null }) {
    const startedAt = now();
    const items = [];
    if (!resolvedDirectory) {
      items.push({ key: 'platform-backups', label: 'Plattformsicherungen', status: 'error',
        detail: 'PLATFORM_BACKUP_DIR ist nicht konfiguriert.' });
    } else {
      if (kind === 'scheduled') {
        try {
          const created = await createUnlocked({ reason: 'scheduled' });
          items.push({ key: 'platform-backup-create', label: 'Automatische Wochensicherung', status: 'ok',
            detail: `Sicherung ${created.id} wurde erstellt (${created.recordCount} Datensätze).` });
        } catch (error) {
          items.push({ key: 'platform-backup-create', label: 'Automatische Wochensicherung', status: 'error',
            detail: `Die Wochensicherung konnte nicht erstellt werden: ${error.expose ? error.message : 'interner Fehler'}` });
        }
      }
      const backups = await list().catch(() => []);
      if (backups.length === 0) {
        items.push({ key: 'platform-backups', label: 'Plattformsicherungen', status: 'error',
          detail: 'Es ist keine Plattformsicherung vorhanden.' });
      } else {
        const ageDays = (now().getTime() - Date.parse(backups[0].createdAt)) / DAY_MS;
        items.push({ key: 'platform-backup-age', label: 'Aktualität der Plattformsicherung',
          status: ageDays <= settings.platformBackupMaxAgeDays ? 'ok' : 'warning',
          detail: `Neueste Sicherung ${backups[0].id} ist ${Math.floor(ageDays)} Tag(e) alt.` });
        const damaged = [];
        for (const entry of backups.slice(1)) {
          try {
            await verifyBackup(entry.id, { fullValidation: false });
          } catch (_) {
            damaged.push(entry.id);
          }
        }
        let newestResult = null;
        let newestError = null;
        try {
          newestResult = await verifyBackup(backups[0].id, { fullValidation: true });
        } catch (error) {
          newestError = error;
          damaged.unshift(backups[0].id);
        }
        items.push({ key: 'platform-backups-integrity', label: 'Integrität aller Plattformsicherungen',
          status: damaged.length === 0 ? 'ok' : 'error',
          detail: damaged.length === 0
            ? `${backups.length} Sicherung(en): Prüfsumme, Verschlüsselung und Format sind intakt.`
            : `${damaged.length} von ${backups.length} Sicherung(en) beschädigt: ${damaged.join(', ')}.` });
        items.push({ key: 'platform-backup-restore-validation', label: 'Probewiederherstellung der neuesten Sicherung',
          status: newestResult ? 'ok' : 'error',
          detail: newestResult
            ? `Wiederherstellung von ${backups[0].id} vollständig validiert: ${newestResult.users} Konten, ${newestResult.organizations} Organisationen, ${newestResult.records} Datensätze.`
            : `Die neueste Sicherung ist nicht wiederherstellbar: ${newestError.expose || newestError.status ? newestError.message : 'interner Fehler'}` });
      }
    }
    items.push(...await checkDatabaseDump());
    const status = worstStatus(items);
    const check = {
      id: `bc-${compactTimestamp(startedAt)}-${crypto.randomBytes(4).toString('hex')}`,
      kind,
      startedAt: startedAt.toISOString(),
      completedAt: now().toISOString(),
      triggeredByUserId: actorUserId,
      status,
      summary: status === 'ok'
        ? 'Alle Sicherungen sind vorhanden, intakt und wiederherstellbar.'
        : status === 'warning'
          ? 'Die Sicherungen sind nutzbar, es gibt aber Hinweise.'
          : 'Mindestens eine Sicherung ist fehlerhaft oder fehlt. Bitte sofort prüfen.',
      items,
      acknowledgedBy: [],
    };
    if (resolvedDirectory) {
      try {
        await updateChecks((checks) => { checks.push(check); });
      } catch (error) {
        console.error('Backup-Prüfergebnis konnte nicht gespeichert werden:', error.message);
      }
    }
    if (status !== 'ok') console.warn(`Backup-Prüfung ${check.id}: ${status} – ${check.summary}`);
    return check;
  }

  async function status(userId) {
    const checks = await readChecks();
    const latest = checks.at(-1) || null;
    const latestScheduled = [...checks].reverse().find((entry) => entry.kind === 'scheduled') || null;
    const backups = await list().catch(() => []);
    const view = (entry) => entry && {
      ...entry,
      acknowledged: entry.acknowledgedBy?.includes(userId) === true,
      acknowledgedBy: undefined,
    };
    const nextSlot = scheduledSlot(now(), settings.scheduleWeekday, settings.scheduleMinutesUtc);
    nextSlot.setUTCDate(nextSlot.getUTCDate() + 7);
    return {
      configured: Boolean(resolvedDirectory),
      dumpCheckConfigured: Boolean(resolvedDumpDirectory),
      running,
      latestCheck: view(latest),
      // The weekly message is the newest scheduled check until acknowledged.
      weeklyMessage: latestScheduled && !latestScheduled.acknowledgedBy?.includes(userId)
        ? view(latestScheduled) : null,
      nextScheduledCheckAt: nextSlot.toISOString(),
      backupCount: backups.length,
      newestBackup: publicMetadata(backups[0]) || null,
    };
  }

  async function acknowledge(checkId, userId) {
    if (!CHECK_ID.test(String(checkId || ''))) throw httpError(404, 'Prüfergebnis nicht gefunden.');
    await updateChecks((checks) => {
      const check = checks.find((entry) => entry.id === checkId);
      if (!check) throw httpError(404, 'Prüfergebnis nicht gefunden.');
      check.acknowledgedBy = Array.isArray(check.acknowledgedBy) ? check.acknowledgedBy : [];
      if (check.acknowledgedBy.includes(userId)) return false;
      check.acknowledgedBy.push(userId);
      check.acknowledgedBy = check.acknowledgedBy.slice(-MAX_ACKNOWLEDGEMENTS_PER_CHECK);
      return true;
    });
  }

  async function restore(id, { actorUserId, actorUsername }) {
    return exclusive('Wiederherstellung', async () => {
      // Validate the source completely before touching anything.
      const { metadata, document } = await readDocument(id);
      await validatedBackup(document, collectionNames, identityProtection, { dryRun: true });
      const safety = await createUnlocked({ reason: 'pre-restore', actorUserId, restoredFromId: id });
      const data = await validatedBackup(document, collectionNames, identityProtection);
      data.auditLogs.push({
        id: `audit-platform-backup-restore-${randomUUID()}`,
        organizationId: PLATFORM_ORGANIZATION_ID,
        unitId: PLATFORM_UNIT_ID,
        timestamp: now().toISOString(),
        actor: actorUsername,
        action: 'restore',
        entity: 'PlatformBackup',
        details: { backupId: metadata.id, backupCreatedAt: metadata.createdAt, safetyBackupId: safety.id },
      });
      const retained = new Set(rawCollection(appData.users).map((user) => String(user.id)));
      for (const entry of await list()) entry.userIds.forEach((userId) => retained.add(userId));
      await applyFullRestore({ appData, collectionNames, dataStore, identityProtection, persistData, data,
        retainIdentityKeyUserIds: [...retained] });
      return { restored: publicMetadata(metadata), safetyBackup: publicMetadata(safety),
        records: Object.values(data).reduce((sum, values) => sum + values.length, 0) };
    });
  }

  async function createManual(actorUserId) {
    if (now().getTime() - lastManualCreate < settings.manualIntervalMs) {
      throw httpError(429, 'Bitte zwischen zwei manuellen Sicherungen mindestens 10 Minuten warten.');
    }
    return exclusive('Sicherung', async () => {
      const created = await createUnlocked({ reason: 'manual', actorUserId });
      lastManualCreate = now().getTime();
      return created;
    });
  }

  async function runManualCheck(actorUserId) {
    if (now().getTime() - lastManualCheck < settings.manualCheckIntervalMs) {
      throw httpError(429, 'Bitte zwischen zwei manuellen Prüfungen mindestens 5 Minuten warten.');
    }
    return exclusive('Prüfung', async () => {
      lastManualCheck = now().getTime();
      return runCheckUnlocked({ kind: 'manual', actorUserId });
    });
  }

  async function runScheduledCheckIfDue() {
    if (running) return null;
    const slot = scheduledSlot(now(), settings.scheduleWeekday, settings.scheduleMinutesUtc);
    const checks = await readChecks();
    if (checks.some((entry) => entry.kind === 'scheduled' && Date.parse(entry.startedAt) >= slot.getTime())) {
      return null;
    }
    return exclusive('Wochenprüfung', () => runCheckUnlocked({ kind: 'scheduled' }));
  }

  function startScheduler({ runInSystem = (callback) => callback() } = {}) {
    if (timer) return;
    const tick = () => runInSystem(() => runScheduledCheckIfDue())
      .catch((error) => {
        // A concurrent manual action delays the weekly check to the next tick.
        if (error.status !== 409) console.error('Wöchentliche Backup-Prüfung fehlgeschlagen:', error);
      });
    timer = setInterval(tick, settings.schedulerIntervalMs);
    timer.unref();
    const initial = setTimeout(tick, 60 * 1000);
    initial.unref();
  }

  function stopScheduler() {
    if (timer) clearInterval(timer);
    timer = null;
  }

  return {
    acknowledge, createManual, list, readDocument, restore, runManualCheck,
    runScheduledCheckIfDue, startScheduler, status, stopScheduler,
    get running() { return running; },
  };
}

function registerPlatformBackupRoutes({ app, authMiddleware, service, verifyReauthentication, users, auditLogs,
  reauthenticationRateLimit = (_req, _res, next) => next() }) {
  function requirePlatformAdministration(req, res, next) {
    if (!isPlatformAdministration(req)) {
      return res.status(403).json({ error: 'Diese Aktion ist nur in der Zentralen Verwaltung für Plattformadministratoren verfügbar.' });
    }
    return next();
  }

  function send(res, error) {
    const status = Number.isInteger(error.status) ? error.status : 500;
    if (status >= 500 && !error.expose) {
      console.error('Plattformsicherung fehlgeschlagen:', error);
      return res.status(status).json({ error: 'Die Sicherungsaktion ist fehlgeschlagen.' });
    }
    return res.status(status).json({ error: error.message });
  }

  function audit(req, action, details) {
    rawCollection(auditLogs).push({
      id: `audit-platform-backup-${action}-${randomUUID()}`,
      organizationId: PLATFORM_ORGANIZATION_ID,
      unitId: PLATFORM_UNIT_ID,
      timestamp: new Date().toISOString(),
      actor: req.user.username,
      action,
      entity: 'PlatformBackup',
      details,
    });
  }

  function withCreator(entry) {
    const user = entry?.createdByUserId
      ? rawCollection(users).find((candidate) => candidate.id === entry.createdByUserId) : null;
    return entry && { ...publicMetadata(entry), createdByName: user ? (user.name || user.username) : null };
  }

  app.get('/api/platform/backups', authMiddleware, requirePlatformAdministration, async (req, res) => {
    try {
      const [backups, status] = await Promise.all([service.list(), service.status(req.user.id)]);
      return res.json({ backups: backups.map(withCreator), status });
    } catch (error) {
      return send(res, error);
    }
  });

  app.post('/api/platform/backups', authMiddleware, requirePlatformAdministration, reauthenticationRateLimit, async (req, res) => {
    if (!await verifyReauthentication(req.user, req.body || {})) {
      return res.status(403).json({ error: 'Passwort oder 2-FA-Code ist nicht korrekt.' });
    }
    try {
      const created = await service.createManual(req.user.id);
      audit(req, 'create', { backupId: created.id, recordCount: created.recordCount });
      await app.locals.persistData();
      return res.status(201).json({ backup: withCreator(created) });
    } catch (error) {
      return send(res, error);
    }
  });

  app.post('/api/platform/backups/checks', authMiddleware, requirePlatformAdministration, async (req, res) => {
    try {
      const check = await service.runManualCheck(req.user.id);
      audit(req, 'check', { checkId: check.id, status: check.status });
      await app.locals.persistData();
      return res.status(201).json({ check: { ...check, acknowledgedBy: undefined } });
    } catch (error) {
      return send(res, error);
    }
  });

  app.post('/api/platform/backups/checks/:id/acknowledge', authMiddleware, requirePlatformAdministration, async (req, res) => {
    try {
      await service.acknowledge(req.params.id, req.user.id);
      return res.status(204).end();
    } catch (error) {
      return send(res, error);
    }
  });

  app.post('/api/platform/backups/:id/restore', authMiddleware, requirePlatformAdministration, reauthenticationRateLimit, async (req, res) => {
    const id = String(req.params.id || '');
    if (!BACKUP_ID.test(id)) return res.status(404).json({ error: 'Sicherung nicht gefunden.' });
    if (req.body?.confirmation !== `SICHERUNG ${id} ZURÜCKSPIELEN`) {
      return res.status(400).json({ error: 'Die Sicherheitsbestätigung fehlt oder ist falsch.' });
    }
    if (!await verifyReauthentication(req.user, req.body)) {
      return res.status(403).json({ error: 'Passwort oder 2-FA-Code ist nicht korrekt.' });
    }
    try {
      const result = await service.restore(id, { actorUserId: req.user.id, actorUsername: req.user.username });
      return res.json({ ...result, reauthenticationRequired: true });
    } catch (error) {
      return send(res, error);
    }
  });
}

function platformBackupOptionsFromEnvironment(env = process.env) {
  return {
    retentionDays: positiveInteger(env.PLATFORM_BACKUP_RETENTION_DAYS, DEFAULTS.retentionDays),
    maximumBackups: positiveInteger(env.PLATFORM_BACKUP_MAX_COUNT, DEFAULTS.maximumBackups),
  };
}

module.exports = {
  BACKUP_ID,
  BACKUP_SCHEMA_VERSION,
  createPlatformBackupService,
  platformBackupOptionsFromEnvironment,
  registerPlatformBackupRoutes,
  scheduledSlot,
};
