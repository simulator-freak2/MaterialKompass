const DEFAULT_BASE_URL = 'https://api.geoapify.com';
const DEFAULT_TIMEOUT_MS = 5_000;
const MAX_RESPONSE_BYTES = 1_000_000;
const MAX_CACHE_ENTRIES = 500;
const DEFAULT_RESULT_LIMIT = 8;

const EU_COUNTRIES = Object.freeze([
  { code: 'at', name: 'Österreich', aliases: ['austria', 'osterreich', 'oesterreich'] },
  { code: 'be', name: 'Belgien', aliases: ['belgium'] },
  { code: 'bg', name: 'Bulgarien', aliases: ['bulgaria'] },
  { code: 'hr', name: 'Kroatien', aliases: ['croatia'] },
  { code: 'cy', name: 'Zypern', aliases: ['cyprus'] },
  { code: 'cz', name: 'Tschechien', aliases: ['czechia', 'czech republic', 'tschechische republik'] },
  { code: 'dk', name: 'Dänemark', aliases: ['denmark', 'danemark', 'daenemark'] },
  { code: 'ee', name: 'Estland', aliases: ['estonia'] },
  { code: 'fi', name: 'Finnland', aliases: ['finland'] },
  { code: 'fr', name: 'Frankreich', aliases: ['france'] },
  { code: 'de', name: 'Deutschland', aliases: ['germany'] },
  { code: 'gr', name: 'Griechenland', aliases: ['greece'] },
  { code: 'hu', name: 'Ungarn', aliases: ['hungary'] },
  { code: 'ie', name: 'Irland', aliases: ['ireland'] },
  { code: 'it', name: 'Italien', aliases: ['italy'] },
  { code: 'lv', name: 'Lettland', aliases: ['latvia'] },
  { code: 'lt', name: 'Litauen', aliases: ['lithuania'] },
  { code: 'lu', name: 'Luxemburg', aliases: ['luxembourg'] },
  { code: 'mt', name: 'Malta', aliases: [] },
  { code: 'nl', name: 'Niederlande', aliases: ['netherlands', 'the netherlands', 'holland'] },
  { code: 'pl', name: 'Polen', aliases: ['poland'] },
  { code: 'pt', name: 'Portugal', aliases: [] },
  { code: 'ro', name: 'Rumänien', aliases: ['romania', 'rumanien'] },
  { code: 'sk', name: 'Slowakei', aliases: ['slovakia'] },
  { code: 'si', name: 'Slowenien', aliases: ['slovenia'] },
  { code: 'es', name: 'Spanien', aliases: ['spain'] },
  { code: 'se', name: 'Schweden', aliases: ['sweden'] },
]);

function normalizeCountry(value) {
  return String(value || '')
    .trim()
    .toLowerCase()
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '');
}

const COUNTRY_CODES = new Map();
const COUNTRIES_BY_CODE = new Map();
for (const country of EU_COUNTRIES) {
  COUNTRIES_BY_CODE.set(country.code, country);
  for (const value of [country.code, country.name, ...country.aliases]) {
    COUNTRY_CODES.set(normalizeCountry(value), country.code);
  }
}
const ALL_EU_COUNTRY_CODES = [...COUNTRIES_BY_CODE.keys()].join(',');

function countryCode(value) {
  return COUNTRY_CODES.get(normalizeCountry(value)) || null;
}

function countryName(code, fallback = '') {
  return COUNTRIES_BY_CODE.get(String(code || '').toLowerCase())?.name
    || String(fallback || '').trim();
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

function normalizeSuggestion(entry) {
  const code = String(entry?.country_code || '').trim().toLowerCase();
  if (!COUNTRIES_BY_CODE.has(code)) return null;
  const street = String(entry?.street || '').trim();
  const houseNumber = String(entry?.housenumber || '').trim();
  const postalCode = String(entry?.postcode || '').trim();
  const city = String(entry?.city || entry?.town || entry?.village
    || entry?.municipality || '').trim();
  const country = countryName(code, entry?.country);
  if (!street || street.length > 255 || houseNumber.length > 32
    || !postalCode || postalCode.length > 32 || !city || city.length > 255
    || !country || country.length > 128) return null;
  const streetLine = [street, houseNumber].filter(Boolean).join(' ');
  const label = `${streetLine}, ${postalCode} ${city}, ${country}`;
  return {
    id: String(entry?.place_id || label).trim(),
    label,
    street,
    houseNumber,
    postalCode,
    city,
    country,
    countryCode: code,
  };
}

function normalizeSuggestions(rows, limit = DEFAULT_RESULT_LIMIT) {
  const seen = new Set();
  const result = [];
  for (const row of rows) {
    const value = normalizeSuggestion(row);
    if (!value) continue;
    const key = [
      value.street,
      value.houseNumber,
      value.postalCode,
      value.city,
      value.countryCode,
    ]
      .join('|').toLocaleLowerCase('de');
    if (seen.has(key)) continue;
    seen.add(key);
    result.push(value);
    if (result.length >= limit) break;
  }
  return result;
}

function createAddressLookupService({
  fetchImpl = globalThis.fetch,
  baseUrl = process.env.GEOAPIFY_BASE_URL || DEFAULT_BASE_URL,
  apiKey = process.env.GEOAPIFY_API_KEY || '',
  timeoutMs = DEFAULT_TIMEOUT_MS,
  cacheTtlMs = 15 * 60 * 1_000,
} = {}) {
  if (typeof fetchImpl !== 'function') throw new Error('Für die Adresssuche ist fetch erforderlich.');
  const cache = new Map();
  const pending = new Map();
  const normalizedApiKey = String(apiKey).trim();
  const configured = Boolean(normalizedApiKey);

  function cached(key) {
    const entry = cache.get(key);
    if (!entry || entry.expiresAt <= Date.now()) {
      cache.delete(key);
      return null;
    }
    // Map insertion order doubles as a small LRU queue.
    cache.delete(key);
    cache.set(key, entry);
    return entry.value;
  }

  function remember(key, value) {
    if (cache.size >= MAX_CACHE_ENTRIES) cache.delete(cache.keys().next().value);
    cache.set(key, { value, expiresAt: Date.now() + cacheTtlMs });
    return value;
  }

  async function cachedOperation(key, operation) {
    const hit = cached(key);
    if (hit) return hit;
    if (pending.has(key)) return pending.get(key);

    const promise = (async () => remember(key, await operation()))();
    pending.set(key, promise);
    try {
      return await promise;
    } finally {
      pending.delete(key);
    }
  }

  async function request(parameters) {
    const url = new URL('/v1/geocode/autocomplete', baseUrl);
    Object.entries({ ...parameters, apiKey: normalizedApiKey })
      .forEach(([key, value]) => url.searchParams.set(key, value));
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
    if (!data || !Array.isArray(data.results)) {
      throw new Error('Der Adressdienst lieferte ein ungültiges Format.');
    }
    return data.results;
  }

  async function suggestions({ query, country, limit = DEFAULT_RESULT_LIMIT }) {
    const normalizedQuery = String(query || '').trim();
    const code = country ? countryCode(country) : null;
    if (normalizedQuery.length < 3 || normalizedQuery.length > 255) {
      return { configured, supported: true, suggestions: [] };
    }
    if (country && !code) {
      return { configured, supported: false, suggestions: [] };
    }
    if (!configured) return { configured: false, supported: true, suggestions: [] };
    const boundedLimit = Math.min(Math.max(Number(limit) || DEFAULT_RESULT_LIMIT, 1), 10);
    const cacheKey = `address\n${code || '*'}\n${boundedLimit}\n${normalizedQuery.toLocaleLowerCase('de')}`;
    return cachedOperation(cacheKey, async () => {
      const rows = await request({
        text: normalizedQuery,
        filter: `countrycode:${code || ALL_EU_COUNTRY_CODES}`,
        lang: 'de',
        limit: String(boundedLimit),
        format: 'json',
      });
      return {
        configured: true,
        supported: true,
        suggestions: normalizeSuggestions(rows, boundedLimit),
      };
    });
  }

  // Compatibility for clients from earlier releases. Both methods now use
  // Geoapify and deliberately return only the requested field.
  async function localities({ country, postalCode }) {
    const normalizedPostalCode = String(postalCode || '').trim();
    const code = countryCode(country);
    if (!code) return { configured, supported: false, suggestions: [] };
    if (!normalizedPostalCode || normalizedPostalCode.length > 32) {
      return { configured, supported: true, suggestions: [] };
    }
    if (!configured) return { configured: false, supported: true, suggestions: [] };

    const comparablePostalCode = normalizedPostalCode
      .toLocaleUpperCase('de').replace(/[\s-]/g, '');
    const cacheKey = `locality\n${code}\n${comparablePostalCode}`;
    return cachedOperation(cacheKey, async () => {
      const rows = await request({
        text: `${normalizedPostalCode} ${countryName(code)}`,
        filter: `countrycode:${code}`,
        lang: 'de',
        limit: '10',
        format: 'json',
      });
      const matchingRows = rows.filter((entry) => {
        const rowCode = String(entry?.country_code || '').trim().toLowerCase();
        const rowPostalCode = String(entry?.postcode || '').trim()
          .toLocaleUpperCase('de').replace(/[\s-]/g, '');
        return rowCode === code && rowPostalCode === comparablePostalCode;
      });
      return {
        configured: true,
        supported: true,
        suggestions: uniqueStrings(matchingRows.map((entry) => (
          entry?.city || entry?.town || entry?.village || entry?.municipality
        ))),
      };
    });
  }

  async function streets({ country, postalCode, city, query }) {
    const result = await suggestions({
      query: `${query} ${postalCode} ${city} ${country}`,
      country,
    });
    return {
      configured: result.configured,
      supported: result.supported,
      suggestions: uniqueStrings(result.suggestions.map((entry) => entry.street)),
    };
  }

  return { suggestions, localities, streets };
}

module.exports = {
  EU_COUNTRIES,
  countryCode,
  countryName,
  createAddressLookupService,
};
