const assert = require('node:assert/strict');
const test = require('node:test');
const { countryCode, countryName, createAddressLookupService } = require('../src/address-lookup');

test('address lookup normalizes all supported EU country names', () => {
  assert.equal(countryCode('Deutschland'), 'de');
  assert.equal(countryCode('Österreich'), 'at');
  assert.equal(countryCode('Frankreich'), 'fr');
  assert.equal(countryCode('Niederlande'), 'nl');
  assert.equal(countryCode('Tschechische Republik'), 'cz');
  assert.equal(countryCode('Schweiz'), null);
  assert.equal(countryName('fr'), 'Frankreich');
});

test('address lookup queries Geoapify through an EU filter, normalizes and caches results', async () => {
  const urls = [];
  const fetchImpl = async (url) => {
    urls.push(url);
    return {
      ok: true,
      async text() {
        return JSON.stringify({
          results: [
            {
              place_id: 'one', street: 'Rue de Rivoli', housenumber: '10',
              postcode: '75001', city: 'Paris', country: 'France', country_code: 'fr',
            },
            {
              place_id: 'duplicate', street: 'Rue de Rivoli', housenumber: '10', postcode: '75001',
              city: 'Paris', country: 'France', country_code: 'fr',
            },
            {
              place_id: 'outside-eu', street: 'Bahnhofstrasse', postcode: '8001',
              city: 'Zürich', country: 'Schweiz', country_code: 'ch',
            },
          ],
        });
      },
    };
  };
  const service = createAddressLookupService({ fetchImpl, apiKey: 'server-secret' });
  const first = await service.suggestions({ query: 'Rue de Riv', country: 'Frankreich' });
  const cached = await service.suggestions({ query: 'Rue de Riv', country: 'Frankreich' });

  assert.deepEqual(first, {
    configured: true,
    supported: true,
    suggestions: [{
      id: 'one',
      label: 'Rue de Rivoli 10, 75001 Paris, Frankreich',
      street: 'Rue de Rivoli',
      houseNumber: '10',
      postalCode: '75001',
      city: 'Paris',
      country: 'Frankreich',
      countryCode: 'fr',
    }],
  });
  assert.deepEqual(cached, first);
  assert.equal(urls.length, 1);
  assert.equal(urls[0].pathname, '/v1/geocode/autocomplete');
  assert.equal(urls[0].searchParams.get('filter'), 'countrycode:fr');
  assert.equal(urls[0].searchParams.get('apiKey'), 'server-secret');
  assert.equal(JSON.stringify(first).includes('server-secret'), false);

  await Promise.all([
    service.suggestions({ query: 'Rue de Rivoli Paris', country: 'Frankreich' }),
    service.suggestions({ query: 'Rue de Rivoli Paris', country: 'Frankreich' }),
  ]);
  assert.equal(urls.length, 2, 'parallel identical requests share one provider call');
});

test('address lookup resolves and caches exact postal-code localities', async () => {
  const urls = [];
  const fetchImpl = async (url) => {
    urls.push(url);
    return {
      ok: true,
      async text() {
        return JSON.stringify({
          results: [
            {
              postcode: '31535', city: 'Neustadt',
              country: 'Germany', country_code: 'de',
            },
            {
              postcode: '31535', town: 'Neustadt am Rübenberge',
              country: 'Germany', country_code: 'de',
            },
            {
              postcode: '31536', city: 'Falscher Ort',
              country: 'Germany', country_code: 'de',
            },
          ],
        });
      },
    };
  };
  const service = createAddressLookupService({ fetchImpl, apiKey: 'server-secret' });
  const first = await service.localities({
    postalCode: '31535', country: 'Deutschland',
  });
  const cached = await service.localities({
    postalCode: '31535', country: 'Deutschland',
  });

  assert.deepEqual(first, {
    configured: true,
    supported: true,
    suggestions: ['Neustadt', 'Neustadt am Rübenberge'],
  });
  assert.deepEqual(cached, first);
  assert.equal(urls.length, 1);
  assert.equal(urls[0].searchParams.get('filter'), 'countrycode:de');
  assert.equal(urls[0].searchParams.get('text'), '31535 Deutschland');
});

test('address lookup degrades safely without configuration or for non-EU countries', async () => {
  let requests = 0;
  const service = createAddressLookupService({
    apiKey: '',
    fetchImpl: async () => { requests += 1; },
  });
  assert.deepEqual(
    await service.suggestions({ query: 'Hauptstraße', country: 'Deutschland' }),
    { configured: false, supported: true, suggestions: [] },
  );
  assert.deepEqual(
    await service.suggestions({ query: 'Bahnhofstrasse', country: 'Schweiz' }),
    { configured: false, supported: false, suggestions: [] },
  );
  assert.equal(requests, 0);
});
