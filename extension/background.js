/*
 * Mydroid Authenticator: background service worker.
 *
 * Talks to the native messaging host `com.mydroid.otp` (the helper inside Mydroid.app), which relays to the running Mac app.
 * Pages never talk to the host: content scripts send a small request here, and this worker decides the site from the
 * sender's own address, so a page cannot ask for another site's code. Nothing here logs codes, accounts or sites.
 */
'use strict';

const HOST = 'com.mydroid.otp';
const CALL_TIMEOUT_MS = 50000;      // the phone's own approval gives up at 30 s
const OPS = new Set(['code', 'list', 'link', 'status', 'autofill', 'hello']);

let port = null;
let seq = 0;
let lastDisconnect = '';
const pending = new Map();

function failAll(error) {
  for (const [id, p] of pending) { clearTimeout(p.timer); p.resolve({ ok: false, error }); pending.delete(id); }
}

function connect() {
  port = chrome.runtime.connectNative(HOST);
  port.onMessage.addListener((m) => {
    const p = m && pending.get(m.id);
    if (!p) return;
    clearTimeout(p.timer);
    pending.delete(m.id);
    p.resolve(m);
  });
  port.onDisconnect.addListener(() => {
    lastDisconnect = (chrome.runtime.lastError && chrome.runtime.lastError.message) || '';
    port = null;
    // "Specified native messaging host not found" means the manifest isn't installed for this browser.
    failAll(/not found|forbidden/i.test(lastDisconnect) ? 'no_host' : 'no_app');
  });
}

/** One request to the Mac app. Always resolves, with {ok:false, error} on any failure. */
function call(request) {
  return new Promise((resolve) => {
    if (!OPS.has(request.op)) { resolve({ ok: false, error: 'bad_request' }); return; }
    if (!port) { try { connect(); } catch (e) { resolve({ ok: false, error: 'no_host' }); return; } }
    const id = ++seq;
    const timer = setTimeout(() => { pending.delete(id); resolve({ ok: false, error: 'timeout' }); }, CALL_TIMEOUT_MS);
    pending.set(id, { resolve, timer });
    try { port.postMessage(Object.assign({}, request, { id })); }
    catch (e) { clearTimeout(timer); pending.delete(id); port = null; resolve({ ok: false, error: 'no_host' }); }
  });
}

// ---- Which site a request is for

/** The host of the frame that sent the request (https, or http on this machine). Null for anything else. */
function hostOf(sender) {
  try {
    const u = new URL(sender.url || (sender.tab && sender.tab.url) || '');
    const local = u.hostname === 'localhost' || u.hostname === '127.0.0.1';
    if (u.protocol === 'https:' || (u.protocol === 'http:' && local)) return u.hostname;
  } catch (e) { /* fall through */ }
  return null;
}

/** A rough "same site" test for using a remembered username: same last two labels (three under a short country suffix). */
function siteKey(host) {
  const l = String(host).toLowerCase().split('.');
  if (l.length <= 2) return l.join('.');
  const twoPart = l[l.length - 1].length === 2 && l[l.length - 2].length <= 3;
  return l.slice(twoPart ? -3 : -2).join('.');
}

function browserName() {
  try {
    const brands = (navigator.userAgentData && navigator.userAgentData.brands) || [];
    if (brands.some((b) => /edge/i.test(b.brand))) return 'Edge';
    if (brands.some((b) => /brave/i.test(b.brand))) return 'Brave';
    if (brands.some((b) => /opera/i.test(b.brand))) return 'Opera';
  } catch (e) { /* ignore */ }
  return 'Chrome';
}

// ---- The username typed earlier in a tab (session only, never written to disk)

const userKey = (tabId) => 'u' + tabId;

async function rememberUser(tabId, host, user) {
  if (tabId == null || !user) return;
  try { await chrome.storage.session.set({ [userKey(tabId)]: { user, site: siteKey(host) } }); } catch (e) { /* storage unavailable */ }
}

async function recallUser(tabId, host) {
  if (tabId == null) return null;
  try {
    const got = await chrome.storage.session.get(userKey(tabId));
    const v = got[userKey(tabId)];
    return v && v.site === siteKey(host) ? v.user : null;
  } catch (e) { return null; }
}

chrome.tabs.onRemoved.addListener((tabId) => { try { chrome.storage.session.remove(userKey(tabId)); } catch (e) { /* ignore */ } });

// ---- Hello: tells Mydroid for Mac this browser's extension is running (its setup screen waits for it)

let helloSent = false;
let helloAt = 0;

/** Sent when the extension is installed or updated and when the browser starts; never carries anything about pages or accounts. */
async function sayHello() {
  helloAt = Date.now();
  const manifest = chrome.runtime.getManifest();
  const r = await call({ op: 'hello', browser: browserName(), version: manifest.version });
  helloSent = !!(r && r.ok);          // if Mydroid wasn't reachable, the next request tries again
}

chrome.runtime.onInstalled.addListener(() => { sayHello(); });
chrome.runtime.onStartup.addListener(() => { sayHello(); });

// ---- Requests from pages and from the popup

async function handle(msg, sender) {
  if (!helloSent && Date.now() - helloAt > 30000) sayHello();   // once per worker start, and again (at most every 30 s) after a failure
  if (msg.op === 'open-options') { try { chrome.runtime.openOptionsPage(); } catch (e) { /* ignore */ } return { ok: true }; }
  if (msg.op === 'popup-status') {
    const r = await call({ op: 'status', host: msg.host || undefined });
    return r.ok ? { state: r.connected ? 'connected' : 'phone_offline', autofill: !!r.autofill, domain: r.domain || null }
                : { state: r.error === 'no_host' ? 'no_host' : 'no_app' };
  }
  if (msg.op === 'popup-autofill') {
    return call({ op: 'autofill', host: msg.host, on: !!msg.on });
  }

  const host = hostOf(sender);
  if (!host) return { ok: false, error: 'bad_site' };
  const tabId = sender.tab && sender.tab.id;

  switch (msg.op) {
    case 'remember-user':
      await rememberUser(tabId, host, String(msg.user || '').slice(0, 254));
      return { ok: true };
    case 'status':
      return call({ op: 'status', host });
    case 'autofill':
      return call({ op: 'autofill', host, on: !!msg.on });
    case 'list':
      return call({ op: 'list', host });
    case 'link':
      return call({ op: 'link', host, entryId: String(msg.entryId || ''), acknowledged: msg.acknowledged === true });
    case 'code': {
      const account = msg.entryId ? null : await recallUser(tabId, host);
      const base = { op: 'code', host, client: browserName(), entryId: msg.entryId ? String(msg.entryId) : undefined };
      const first = await call(Object.assign({}, base, { account: account || undefined }));
      // A username from earlier in the tab may not be the one for this site's account: ask again without it.
      if (!first.ok && first.error === 'no_match' && account) return call(base);
      return first;
    }
    default:
      return { ok: false, error: 'bad_request' };
  }
}

chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  // Only this extension's own pages and content scripts.
  if (!msg || typeof msg.op !== 'string' || sender.id !== chrome.runtime.id) return false;
  handle(msg, sender).then(sendResponse, () => sendResponse({ ok: false, error: 'failed' }));
  return true;
});
