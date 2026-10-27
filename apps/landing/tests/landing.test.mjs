import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {fileURLToPath, pathToFileURL} from 'node:url';
import path from 'node:path';
import {parseHTML} from 'linkedom';

const root = fileURLToPath(new URL('../../../', import.meta.url));
const site = process.env.SITE_DIRECTORY || path.join(root, 'build/site');
let sequence = 0;

async function openPage({language = 'es', address = 'http://localhost:8080/', saved = null, blockedStorage = false} = {}) {
  const filename = language === 'en' ? 'en/index.html' : 'index.html';
  const source = await readFile(path.join(site, filename), 'utf8');
  const {document} = parseHTML(source);
  const stored = new Map(saved ? [['circuitlab.language', saved]] : []);
  const callbacks = new Map();
  const location = new URL(address);
  let redirect = null;
  location.replace = value => { redirect = value; };
  globalThis.document = document;
  globalThis.location = location;
  globalThis.history = {replaceState(_data, _title, value) { location.href = new URL(value, location).href; }};
  globalThis.localStorage = {
    getItem(key) { if (blockedStorage) throw new Error('Storage unavailable'); return stored.get(key) ?? null; },
    setItem(key, value) { if (blockedStorage) throw new Error('Storage unavailable'); stored.set(key, value); },
  };
  Object.defineProperty(globalThis, 'navigator', {value: {language: 'es-BO'}, configurable: true});
  globalThis.addEventListener = (name, callback) => callbacks.set(name, callback);
  const module = await import(pathToFileURL(path.join(root, 'apps/landing/assets/landing.js')).href + '?test=' + ++sequence);
  return {document, stored, callbacks, location, module, redirect: () => redirect};
}

test('Both languages are rendered before JavaScript with valid section links', async () => {
  for (const language of ['es', 'en']) {
    const source = await readFile(path.join(site, language === 'en' ? 'en/index.html' : 'index.html'), 'utf8');
    assert.ok(!source.includes('{{'));
    const {document} = parseHTML(source);
    assert.equal(document.documentElement.lang, language);
    assert.equal(document.querySelectorAll('h1').length, 1);
    assert.equal(document.querySelectorAll('details').length, 4);
    assert.ok(document.querySelector('meta[name="description"]').content.length > 80);
    for (const anchor of document.querySelectorAll('a[href^="#"]')) {
      assert.ok(document.getElementById(anchor.getAttribute('href').slice(1)));
    }
    const catalogs = JSON.parse(document.getElementById('landing-messages').textContent);
    assert.deepEqual(Object.keys(catalogs.es).sort(), Object.keys(catalogs.en).sort());
    for (const element of document.querySelectorAll('[data-i18n]')) {
      assert.ok(catalogs[language][element.getAttribute('data-i18n')]);
    }
  }
});

test('Switching language translates content, metadata, accessible labels and app links', async () => {
  const page = await openPage();
  page.document.querySelector('[data-language="en"]').click();
  assert.equal(page.document.documentElement.lang, 'en');
  assert.equal(page.document.title, 'CircuitLab AI · From faults to evidence');
  assert.ok(page.document.querySelector('h1').textContent.includes('Understand the fault.'));
  assert.ok(!page.document.querySelector('main').textContent.includes('Entiende la falla.'));
  assert.equal(page.document.querySelector('nav').getAttribute('aria-label'), 'Main navigation');
  assert.equal(page.stored.get('circuitlab.language'), 'en');
  assert.equal(page.location.pathname, '/en/');
  for (const link of page.document.querySelectorAll('[data-app-link]')) {
    assert.equal(link.getAttribute('href'), '/app/?lang=en');
  }
  page.document.querySelector('[data-language="es"]').click();
  assert.equal(page.document.documentElement.lang, 'es');
  assert.equal(page.location.pathname, '/');
});

test('The illustrative circuit cycle is interactive and keeps its stage when language changes', async () => {
  const page = await openPage();
  page.document.querySelector('[data-step="measure"]').click();
  assert.equal(page.document.querySelector('.circuit-demo').dataset.stage, 'measure');
  assert.ok(page.document.getElementById('reading-value').textContent.includes('2,50'));
  page.document.querySelector('[data-language="en"]').click();
  assert.ok(page.document.getElementById('reading-value').textContent.includes('2.50'));
  assert.equal(page.document.getElementById('stage-title').textContent, 'A test with a purpose.');
  page.document.querySelector('[data-step="verify"]').click();
  assert.equal(page.document.querySelector('[data-step="verify"]').getAttribute('aria-pressed'), 'true');
  assert.ok(page.document.querySelector('.example-note').textContent.includes('do not represent a real measurement'));
});

test('Saved language and explicit English URLs work without a pageshow reset', async () => {
  const saved = await openPage({saved: 'en'});
  assert.equal(saved.document.documentElement.lang, 'en');
  const explicit = await openPage({language: 'en', address: 'http://localhost:8080/en/', saved: 'es'});
  explicit.callbacks.get('pageshow')({persisted: false});
  assert.equal(explicit.document.documentElement.lang, 'en');
  explicit.callbacks.get('pageshow')({persisted: true});
  assert.equal(explicit.document.documentElement.lang, 'es');
});

test('Storage failures still allow choosing a language and passing it into the app', async () => {
  const page = await openPage({blockedStorage: true});
  page.document.querySelector('[data-language="en"]').click();
  assert.equal(page.document.querySelector('[data-app-link]').getAttribute('href'), '/app/?lang=en');
  assert.equal(page.document.documentElement.lang, 'en');
});

test('Existing session links continue into the laboratory and preserve their identifier', async () => {
  for (const address of ['http://localhost:8080/?session=existing-session&lang=en', 'http://localhost:8080/#/?session=existing-session']) {
    const page = await openPage({address});
    const target = new URL(page.redirect(), 'http://localhost:8080/');
    assert.equal(target.pathname, '/app/');
    assert.equal(new URLSearchParams(target.hash.slice(3)).get('session'), 'existing-session');
  }
});


test('Public signup, platform guidance and homepage links follow the selected language', async () => {
  const page = await openPage();
  assert.ok(page.document.getElementById('download'));
  assert.equal(page.document.querySelector('[data-register-link]').getAttribute('href'), '/app/?lang=es#/register');
  page.document.querySelector('[data-language="en"]').click();
  assert.equal(page.document.querySelector('[data-register-link]').getAttribute('href'), '/app/?lang=en#/register');
  for (const link of page.document.querySelectorAll('[data-home-link]')) assert.equal(link.getAttribute('href'), '/en/');
  assert.ok(page.document.querySelector('#download').textContent.includes('same account'));
  assert.ok(page.document.querySelector('#how-it-works').textContent.includes('remains unverified'));
});
