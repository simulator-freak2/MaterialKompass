const assert = require('node:assert/strict');
const test = require('node:test');

const { createApp } = require('../src/app');

test('regular API startup leaves optional document processors unloaded', () => {
  createApp();
  const loadedModules = Object.keys(require.cache).map((file) => file.replaceAll('\\', '/'));
  for (const optionalModule of [
    '/node_modules/@napi-rs/canvas/',
    '/node_modules/pdf-lib/',
    '/node_modules/pdfjs-dist/',
    '/node_modules/sharp/',
    '/node_modules/tesseract.js/',
    '/node_modules/xlsx/',
  ]) {
    assert.equal(
      loadedModules.some((file) => file.includes(optionalModule)),
      false,
      `${optionalModule} must be loaded only by its feature`,
    );
  }
});
