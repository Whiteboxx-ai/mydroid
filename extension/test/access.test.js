'use strict';
// Run with: node test/access.test.js
// The extension asks for website access at runtime. Checks the manifest and the background worker's side of it with a fake `chrome`.
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const manifest = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'manifest.json'), 'utf8'));

function load({ granted = [], active = null } = {}) {
  const on = { installed: [], startup: [], added: [], removed: [] };
  const state = { registered: [], created: [], executed: [], granted: [...granted] };
  const chrome = {
    runtime: {
      id: 'ext', lastError: null, getManifest: () => manifest, getURL: (p) => 'chrome-extension://ext/' + p,
      onInstalled: { addListener: (f) => on.installed.push(f) }, onStartup: { addListener: (f) => on.startup.push(f) },
      onMessage: { addListener() {} }, connectNative() { throw new Error('not found'); },
    },
    tabs: {
      onRemoved: { addListener() {} },
      create: (o) => state.created.push(o.url),
      query: async () => (active ? [active] : []),
    },
    storage: { session: { set: async () => {}, get: async () => ({}), remove: async () => {} } },
    permissions: {
      onAdded: { addListener: (f) => on.added.push(f) }, onRemoved: { addListener: (f) => on.removed.push(f) },
      getAll: async () => ({ origins: state.granted }),
      contains: async ({ origins }) => origins.every((o) => state.granted.includes(o) || state.granted.includes('https://*/*')),
    },
    scripting: {
      getRegisteredContentScripts: async () => state.registered,
      registerContentScripts: async (s) => { state.registered = s; },
      updateContentScripts: async (s) => { state.registered = s; },
      unregisterContentScripts: async () => { state.registered = []; },
      executeScript: async (o) => { state.executed.push(o); },
    },
  };
  const ctx = { chrome, navigator: { userAgentData: { brands: [] } }, setTimeout, clearTimeout, URL, Date, console, Promise, Map };
  vm.createContext(ctx);
  vm.runInContext(fs.readFileSync(path.join(__dirname, '..', 'background.js'), 'utf8'), ctx);
  return { on, state };
}
const tick = () => new Promise((r) => setTimeout(r, 20));
let n = 0;
async function test(name, fn) { await fn(); n++; console.log('ok  ' + name); }

(async () => {
  await test('the manifest asks for no website access up front', () => {
    assert.strictEqual(manifest.content_scripts, undefined);
    assert.strictEqual(manifest.host_permissions, undefined);
    assert.ok(manifest.permissions.includes('scripting'));
    assert.ok(manifest.optional_host_permissions.includes('https://*/*'));
  });

  await test('a first install opens the welcome page; an update does not', async () => {
    const t = load();
    t.on.installed[0]({ reason: 'install' });
    t.on.installed[0]({ reason: 'update' });
    await tick();
    assert.deepStrictEqual(t.state.created, ['chrome-extension://ext/welcome.html']);
    assert.ok(fs.existsSync(path.join(__dirname, '..', 'welcome.html')));
  });

  await test('granting access registers the content script for exactly those sites', async () => {
    const t = load({ granted: ['https://example.com/*', 'chrome://favicon/*'] });
    t.on.installed[0]({ reason: 'update' });
    await tick();
    assert.strictEqual(t.state.registered.length, 1);
    assert.deepStrictEqual([...t.state.registered[0].matches], ['https://example.com/*']);
    assert.deepStrictEqual([...t.state.registered[0].js], ['detector.js', 'content.js']);
    assert.strictEqual(t.state.registered[0].allFrames, true);
    assert.strictEqual(t.state.registered[0].persistAcrossSessions, true);
  });

  await test('removing every site unregisters the script', async () => {
    const t = load({ granted: ['https://*/*'] });
    t.on.startup[0]();
    await tick();
    assert.strictEqual(t.state.registered.length, 1);
    t.state.granted = [];
    t.on.removed[0]({ origins: ['https://*/*'] });
    await tick();
    assert.strictEqual(t.state.registered.length, 0);
  });

  await test('a new grant also starts the script in the tab the user is on', async () => {
    const t = load({ granted: ['https://*/*'], active: { id: 7, url: 'https://login.example.com/2fa' } });
    t.on.added[0]({ origins: ['https://*/*'] });
    await tick();
    assert.strictEqual(t.state.executed.length, 1);
    assert.strictEqual(t.state.executed[0].target.tabId, 7);
    assert.strictEqual(t.state.executed[0].target.allFrames, true);
  });

  await test('a tab on a site that was not allowed is left alone', async () => {
    const t = load({ granted: ['https://example.com/*'], active: { id: 7, url: 'https://other.test/' } });
    t.on.added[0]({ origins: ['https://example.com/*'] });
    await tick();
    assert.strictEqual(t.state.executed.length, 0);
  });

  console.log(`\n${n} access checks passed`);
})().catch((e) => { console.error(e); process.exit(1); });
