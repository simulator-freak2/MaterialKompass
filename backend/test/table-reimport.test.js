const assert = require('node:assert/strict');
const test = require('node:test');
const XLSX = require('xlsx');
const { createApp } = require('../src/app');
const { seedData } = require('../src/data/seed');

for (const format of ['xlsx', 'ods']) for (const kind of ['material', 'clothing']) {
  test(kind + ' reimport: preview, deleted numbers, mapping and conflict policies (' + format + ')', async () => {
    const data = structuredClone(seedData);
    const material = { ...data.materials[0], id: 'material-901', inventoryNumber: 'REIMPORT-M',
      name: 'Alt', categoryCode: '02', subcategoryCode: '02-02', locationId: 'loc-1',
      stockStructureId: null, itemType: 'bulk', quantity: 20, issuedQuantity: 2,
      manufacturer: 'Erhalten', archived: false };
    const clothing = { ...data.clothingItems[0], id: 'clothing-901', inventoryNumber: 'REIMPORT-C',
      name: 'Alt', categoryId: null, size: 'L', locationId: 'loc-2', stockStructureId: null,
      manufacturer: 'Erhalten', status: 'Ausgegeben', assignedPerson: 'Person', archived: false };
    data.deletedMaterials ||= []; data.deletedClothingItems ||= [];
    data.materials.push(material); data.clothingItems.push(clothing);
    const own = kind === 'material' ? material : clothing;
    const deleted = { ...own, id: kind + '-902', inventoryNumber: 'DELETED-NUMBER', deletedAt: '2026-01-01' };
    (kind === 'material' ? data.deletedMaterials : data.deletedClothingItems).push(deleted);
    const app = createApp({ data });
    const server = await new Promise(resolve => { const s = app.listen(0, '127.0.0.1', () => resolve(s)); });
    const base = 'http://127.0.0.1:' + server.address().port;
    try {
      const login = await fetch(base + '/api/auth/login', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ email: 'admin@materialkompass.org', password: 'MaterialKompass2026!' }) }).then(r => r.json());
      const headers = { 'Content-Type': 'application/json', Authorization: 'Bearer ' + login.token };
      const call = async (rows, options = {}) => {
        const workbook = XLSX.utils.book_new(); XLSX.utils.book_append_sheet(workbook, XLSX.utils.json_to_sheet(rows), 'Import');
        const response = await fetch(base + '/api/' + kind + '/import', { method: 'POST', headers, body: JSON.stringify({ fileName: 'import.' + format, fileBase64: XLSX.write(workbook, { type: 'buffer', bookType: format }).toString('base64'), ...options }) });
        return { status: response.status, body: await response.json() };
      };
      const row = { Inventarnummer: own.inventoryNumber, Name: 'Neu', Bezeichnung: 'Neu', Hersteller: '', Standort: own.locationId };
      let result = await call([row], { preview: true });
      assert.equal(result.body.conflicts.length, 1);
      const list = async () => fetch(base + '/api/' + kind, { headers }).then(r => r.json());
      assert.equal((await list()).find(item => item.id === own.id).name, 'Alt');
      result = await call([row], { conflictPolicy: 'skip' });
      assert.equal(result.body.skipped, 1);
      result = await call([row], { conflictPolicy: 'replace' });
      assert.equal(result.body.replaced, 1);
      const replaced = (await list()).find(item => item.id === own.id);
      assert.equal(replaced.name, 'Neu'); assert.equal(replaced.manufacturer, 'Erhalten');
      if (kind === 'material') assert.equal(replaced.issuedQuantity, 2);
      else assert.equal(replaced.assignedPerson, 'Person');
      const complete = { ...row, Hauptkategorie: '02', Unterkategorie: '02-02', Status: 'Lagernd', 'Größe': 'L' };
      result = await call([complete], { conflictPolicy: 'renumber' });
      assert.equal(result.body.imported, 1); assert.equal(result.body.renumbered, 1);
      result = await call([{ ...complete, Inventarnummer: 'BATCH-DUPLICATE', Hersteller: 'Bleibt' },
        { ...complete, Inventarnummer: 'BATCH-DUPLICATE', Name: 'Letzte Zeile', Bezeichnung: 'Letzte Zeile', Hersteller: '' }], { conflictPolicy: 'replace' });
      assert.equal(result.body.imported, 1); assert.equal(result.body.replaced, 1);
      assert.equal((await list()).find(item => item.inventoryNumber === 'BATCH-DUPLICATE').manufacturer, 'Bleibt');
      if (kind === 'material') {
        result = await call([{ ...complete, Inventarnummer: 'LEGACY-QUANTITY', Anzahl: 7 }]);
        assert.equal(result.body.imported, 1);
        assert.equal((await list()).find(item => item.inventoryNumber === 'LEGACY-QUANTITY').quantity, 7);
      }
      assert.equal(new Set((await list()).map(item => item.inventoryNumber)).size, (await list()).length);
      const recovery = { ...complete, Inventarnummer: 'DELETED-NUMBER', Standort: 'old-location', Lagerplatz: 'old-position' };
      result = await call([recovery], { preview: true });
      assert.equal(result.body.conflicts.length, 0); assert.equal(result.body.missingStorage.length, 1);
      const mappingKey = result.body.missingStorage[0].key;
      result = await call([recovery]); assert.equal(result.status, 409);
      assert.ok(!(await list()).some(item => item.inventoryNumber === 'DELETED-NUMBER'));
      result = await call([recovery], { storageMappings: { [mappingKey]: { locationId: own.locationId, stockStructureId: '' } } });
      assert.equal(result.body.imported, 1);
      const recovered = (await list()).find(item => item.inventoryNumber === 'DELETED-NUMBER');
      assert.ok(recovered && recovered.id !== deleted.id);
      const edited = await fetch(base + '/api/' + kind + '/' + recovered.id, { method: 'PUT', headers,
        body: JSON.stringify({ name: 'Wieder bearbeitbar' }) });
      assert.equal(edited.status, 200);
    } finally { server.close(); }
  });
}
