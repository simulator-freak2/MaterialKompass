const assert = require('node:assert/strict');
const test = require('node:test');
const { countryCode, createAddressLookupService } = require('../src/address-lookup');

test('address lookup normalizes supported country names', () => {
  assert.equal(countryCode('Deutschland'), 'de');
  assert.equal(countryCode('Österreich'), 'at');
  assert.equal(countryCode('Schweiz'), 'ch');
  assert.equal(countryCode('Liechtenstein'), 'li');
  assert.equal(countryCode('Frankreich'), null);
});

test('address lookup queries OpenPLZ safely, deduplicates and caches results', async () => {
  const urls = [];
  const fetchImpl = async (url) => {
    urls.push(url);
    const rows = url.pathname.endsWith('/Localities')
      ? [{ name: 'Neustadt' }, { name: 'Neustadt' }, { name: 'Neustadt am Rübenberge' }]
      : [{ name: 'Hauptstraße' }, { name: 'Hauptstraße' }, { name: 'Hauptweg' }];
    return {
      ok: true,
      async text() { return JSON.stringify(rows); },
    };
  };
  const service = createAddressLookupService({ fetchImpl });
  const first = await service.localities({ country: 'Deutschland', postalCode: '31535' });
  const cached = await service.localities({ country: 'Deutschland', postalCode: '31535' });
  assert.deepEqual(first.suggestions, ['Neustadt', 'Neustadt am Rübenberge']);
  assert.deepEqual(cached, first);
  assert.equal(urls.length, 1);
  assert.equal(urls[0].pathname, '/de/Localities');
  assert.equal(urls[0].searchParams.get('postalCode'), '31535');

  const streets = await service.streets({
    country: 'Deutschland', postalCode: '31535', city: 'Neustadt', query: 'Hau.*',
  });
  assert.deepEqual(streets.suggestions, ['Hauptstraße', 'Hauptweg']);
  assert.equal(urls[1].pathname, '/de/Streets');
  assert.equal(urls[1].searchParams.get('name'), '^Hau\\.\\*');
  assert.equal(urls[1].searchParams.get('locality'), 'Neustadt');

  const unsupported = await service.localities({
    country: 'Frankreich', postalCode: '75001',
  });
  assert.deepEqual(unsupported, { supported: false, suggestions: [] });
  assert.equal(urls.length, 2);
});
