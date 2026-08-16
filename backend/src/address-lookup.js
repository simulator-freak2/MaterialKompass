const DEFAULT_BASE_URL = 'https://openplzapi.org';
const DEFAULT_TIMEOUT_MS = 5_000;
const MAX_RESPONSE_BYTES = 1_000_000;
const MAX_CACHE_ENTRIES = 500;

const COUNTRY_CODES = new Map([
  ['de', 'de'],
  ['deutschland', 'de'],
  ['germany', 'de'],
  ['at', 'at'],
  ['austria', 'at'],
  ['osterreich', 'at'],
  ['oesterreich', 'at'],
  ['ch', 'ch'],
  ['schweiz', 'ch'],
  ['switzerland', 'ch'],
  ['suisse', 'ch'],
  ['svizzera', 'ch'],
  ['li', 'li'],
  ['liechtenstein', 'li'],
]);

function normalizeCountry(value) {
  return String(value || '')
    .trim()
    .toLowerCase()
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '');
}

function countryCode(value) {
  return COUNTRY_CODES.get(normalizeCountry(value)) || null;
}

function escapeRegularExpression(value) {
  return String(value).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function uniqueStrings(values, limit = 20) {
  const seen = new Set();
  const result = [];
  for (const value of values) {
    const normalized = String(value || '').trim();
    const key = normalized.toLocaleLowerCase('de');
    if (!normalized || seen.has(key)) continue;
    seen.add(key);
    result.push(normalized);
    if (result.length >= limit) break;
  }
  return result;
}

function createAddressLookupService({
  fetchImpl = globalThis.fetch,
  baseUrl = process.env.ADDRESS_LOOKUP_BASE_URL || DEFAULT_BASE_URL,
  timeoutMs = DEFAULT_TIMEOUT_MS,
  cacheTtlMs = 15 * 60 * 1_000,
} = {}) {
  if (typeof fetchImpl !== 'function') throw new Error('Für die Adresssuche ist fetch erforderlich.');
  const cache = new Map();

  function cached(key) {
    const entry = cache.get(key);
    if (!entry || entry.expiresAt <= Date.now()) {
      cache.delete(key);
      return null;
    }
    return entry.value;
  }

  function remember(key, value) {
    if (cache.size >= MAX_CACHE_ENTRIES) cache.delete(cache.keys().next().value);
    cache.set(key, { value, expiresAt: Date.now() + cacheTtlMs });
    return value;
  }

  async function request(path, parameters) {
    const url = new URL(path, baseUrl);
    Object.entries(parameters).forEach(([key, value]) => url.searchParams.set(key, value));
    const key = url.toString();
    const hit = cached(key);
    if (hit) return hit;
    const response = await fetchImpl(url, {
      headers: {
        Accept: 'application/json',
        'User-Agent': 'MaterialKompass/1.0 address lookup',
      },
      signal: AbortSignal.timeout(timeoutMs),
    });
    if (!response.ok) throw new Error(`Adressdienst antwortete mit Status ${response.status}.`);
    const text = await response.text();
    if (Buffer.byteLength(text, 'utf8') > MAX_RESPONSE_BYTES) {
      throw new Error('Die Antwort des Adressdienstes ist zu groß.');
    }
    const data = JSON.parse(text);
    if (!Array.isArray(data)) throw new Error('Der Adressdienst lieferte ein ungültiges Format.');
    return remember(key, data);
  }

  async function localities({ country, postalCode }) {
    const code = countryCode(country);
    if (!code) return { supported: false, suggestions: [] };
    const normalizedPostalCode = String(postalCode || '').trim();
    if (!normalizedPostalCode || normalizedPostalCode.length > 32) {
      return { supported: true, suggestions: [] };
    }
    const rows = await request(`/${code}/Localities`, {
      postalCode: normalizedPostalCode,
    });
    return {
      supported: true,
      suggestions: uniqueStrings(rows.map((entry) => entry.name)),
    };
  }

  async function streets({ country, postalCode, city, query }) {
    const code = countryCode(country);
    if (!code) return { supported: false, suggestions: [] };
    const normalizedQuery = String(query || '').trim();
    const normalizedPostalCode = String(postalCode || '').trim();
    const normalizedCity = String(city || '').trim();
    if (normalizedQuery.length < 3 || normalizedQuery.length > 255
      || !normalizedPostalCode || normalizedPostalCode.length > 32
      || !normalizedCity || normalizedCity.length > 255) {
      return { supported: true, suggestions: [] };
    }
    const rows = await request(`/${code}/Streets`, {
      name: `^${escapeRegularExpression(normalizedQuery)}`,
      postalCode: normalizedPostalCode,
      locality: normalizedCity,
    });
    return {
      supported: true,
      suggestions: uniqueStrings(rows.map((entry) => entry.name)),
    };
  }

  return { localities, streets };
}

module.exports = { countryCode, createAddressLookupService };
