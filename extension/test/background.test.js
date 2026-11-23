'use strict';
// Run with: node test/background.test.js
// Loads background.js against a fake `chrome` and checks the hello it sends when the extension is installed or the browser starts.
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

function load(opts = {}) {
  const listeners = { installed: [], startup: [], message: [] };
  const posted = [];
  let connects = 0;
  const chrome = {
    runtime: {
      id: 'ext', lastError: null,
      getManifest: () => ({ version: '9.9.9' }),
      onInstalled: { addListener: (f) => listeners.installed.push(f) },
      onStartup: { addListener: (f) => listeners.startup.push(f) },
      onMessage: { addListener: (f) => listeners.message.push(f) },
      openOptionsPage: () => { posted.push({ opened: true }); },
      connectNative(host) {
        connects++;
        assert.strictEqual(host, 'com.mydroid.otp');
        if (opts.throws) throw new Error('Specified native messaging host not found.');
        const l = { msg: [], disc: [] };
        return {
          onMessage: { addListener: (f) => l.msg.push(f) },
          onDisconnect: { addListener: (f) => l.disc.push(f) },
          postMessage(m) { posted.push(m); setTimeout(() => l.msg.forEach((f) => f({ id: m.id, ok: true, running: true }))); },
        };
      },
    },
    tabs: { onRemoved: { addListener() {} } },
    storage: { session: { set: async () => {}, get: async () => ({}), remove: async () => {} } },
  };
  const ctx = { chrome, navigator: { userAgentData: { brands: opts.brands || [{ brand: 'Google Chrome' }] } }, setTimeout, clearTimeout, URL, Date, console, Promise, Map, Set };
  vm.createContext(ctx);
  vm.runInContext(fs.readFileSync(path.join(__dirname, '..', 'background.js'), 'utf8'), ctx);
  return { listeners, posted, connects: () => connects };
}
const tick = () => new Promise((r) => setTimeout(r, 20));
let n = 0;
async function test(name, fn) { await fn(); n++; console.log('ok  ' + name); }

(async () => {
  await test('says hello when installed, with the browser and the version and nothing else', async () => {
    const t = load();
    assert.strictEqual(t.listeners.installed.length, 1);
    t.listeners.installed[0]({ reason: 'install' });
    await tick();
    assert.strictEqual(t.posted.length, 1);
    const m = t.posted[0];
    assert.strictEqual(m.op, 'hello');
    assert.strictEqual(m.browser, 'Chrome');
    assert.strictEqual(m.version, '9.9.9');
    assert.deepStrictEqual(Object.keys(m).sort(), ['browser', 'id', 'op', 'version']);
  });

  await test('says hello when the browser starts', async () => {
    const t = load({ brands: [{ brand: 'Microsoft Edge' }] });
    t.listeners.startup[0]();
    await tick();
    assert.strictEqual(t.posted[0].op, 'hello');
    assert.strictEqual(t.posted[0].browser, 'Edge');
  });

  await test('a missing host never throws', async () => {
    const t = load({ throws: true });
    t.listeners.installed[0]({ reason: 'install' });
    await tick();
    assert.strictEqual(t.posted.length, 0);
  });

  await test('the first request from a page also says hello (the extension may have been loaded before Mydroid was connected)', async () => {
    const t = load();
    const reply = new Promise((resolve) => t.listeners.message[0]({ op: 'open-options' }, { id: 'ext' }, resolve));
    assert.strictEqual(JSON.stringify(await reply), '{"ok":true}');
    await tick();
    assert.ok(t.posted.some((m) => m.op === 'hello'));
  });

  await test('hello is not a request a page can send (only the worker sends it)', async () => {
    const t = load();
    const reply = await new Promise((resolve) => t.listeners.message[0]({ op: 'hello' }, { id: 'ext', url: 'https://example.com/', tab: { id: 1 } }, resolve));
    assert.strictEqual(reply.ok, false);
  });

  console.log(`\n${n} background checks passed`);
})().catch((e) => { console.error('FAIL ' + e.message); process.exit(1); });
