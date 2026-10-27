const catalogs = JSON.parse(document.getElementById('landing-messages').textContent);
const supported = new Set(['es', 'en']);
const preferenceKey = 'circuitlab.language';
let language = document.documentElement.lang;
let step = 'evidence';

export function appHref(selectedLanguage, session = null) {
  const query = new URLSearchParams({lang: supported.has(selectedLanguage) ? selectedLanguage : 'es'});
  const route = session ? '#/?' + new URLSearchParams({session}) : '';
  return '/app/?' + query + route;
}

function readPreference() {
  try { return localStorage.getItem(preferenceKey); } catch { return null; }
}

function renderStep() {
  const text = catalogs[language];
  document.querySelector('.circuit-demo').dataset.stage = step;
  document.querySelectorAll('[data-step]').forEach(button => button.setAttribute('aria-pressed', String(button.dataset.step === step)));
  const prefix = {evidence: 'evidence', measure: 'measure', verify: 'verify'}[step];
  const title = document.getElementById('stage-title');
  const body = document.getElementById('stage-body');
  title.setAttribute('data-i18n', prefix + 'Title');
  body.setAttribute('data-i18n', prefix + 'Body');
  title.textContent = text[prefix + 'Title'];
  body.textContent = text[prefix + 'Body'];
  const reading = document.getElementById('reading-value');
  reading.replaceChildren(document.createTextNode(step === 'evidence' ? '— ' : (language === 'es' ? '2,50 ' : '2.50 ')));
  const unit = document.createElement('small');
  unit.textContent = 'V';
  reading.append(unit);
  const state = document.getElementById('reading-state');
  const stateKey = step === 'evidence' ? 'readingHint' : 'criterion';
  state.setAttribute('data-i18n', stateKey);
  state.textContent = text[stateKey];
}

export function applyLanguage(value, {save = false, updateUrl = true} = {}) {
  if (!supported.has(value)) return;
  language = value;
  const text = catalogs[value];
  document.documentElement.lang = value;
  document.title = text.pageTitle;
  document.querySelectorAll('[data-i18n]').forEach(element => { element.textContent = text[element.getAttribute('data-i18n')]; });
  document.querySelectorAll('[data-i18n-content]').forEach(element => { element.setAttribute('content', text[element.getAttribute('data-i18n-content')]); });
  document.querySelectorAll('[data-i18n-aria-label]').forEach(element => { element.setAttribute('aria-label', text[element.getAttribute('data-i18n-aria-label')]); });
  document.querySelectorAll('[data-language]').forEach(button => { button.setAttribute('aria-pressed', String(button.dataset.language === value)); });
  document.querySelectorAll('[data-app-link]').forEach(link => { link.setAttribute('href', appHref(value)); });
  document.querySelectorAll('[data-register-link]').forEach(link => link.setAttribute('href', appHref(value) + '#/register'));
  document.querySelectorAll('[data-home-link]').forEach(link => link.setAttribute('href', value === 'en' ? '/en/' : '/'));
  document.querySelectorAll('.brand').forEach(link => { link.setAttribute('href', value === 'en' ? '/en/' : '/'); });
  if (save) { try { localStorage.setItem(preferenceKey, value); } catch { /* The URL still carries the language into the application. */ } }
  if (updateUrl) {
    const target = new URL(location.href);
    target.pathname = value === 'en' ? '/en/' : '/';
    target.searchParams.delete('lang');
    try { history.replaceState(null, '', target); } catch { /* Language switching remains usable without history access. */ }
  }
  renderStep();
}

document.querySelectorAll('[data-language]').forEach(button => button.addEventListener('click', () => applyLanguage(button.dataset.language, {save: true})));
document.querySelectorAll('[data-step]').forEach(button => button.addEventListener('click', () => { step = button.dataset.step; renderStep(); }));

const url = new URL(location.href);
const requested = url.searchParams.get('lang');
const preferred = readPreference();
const initial = supported.has(requested) ? requested : location.pathname.startsWith('/en/') ? 'en' : supported.has(preferred) ? preferred : navigator.language?.startsWith('en') ? 'en' : 'es';
applyLanguage(initial, {save: supported.has(requested)});

// Preserve links shared before the landing page was introduced.
const legacyQuery = new URLSearchParams(location.hash.replace(/^#\/?\??/, ''));
const legacySession = url.searchParams.get('session') || legacyQuery.get('session');
if (legacySession) location.replace(appHref(language, legacySession));
addEventListener('pageshow', event => {
  if (!event.persisted) return;
  const selected = readPreference();
  if (supported.has(selected) && selected !== language) applyLanguage(selected);
});
