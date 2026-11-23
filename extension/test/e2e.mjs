// Drives test/fixtures.html in a headless Chrome with a throwaway profile (never your own browser) over the DevTools protocol.
// It clicks the chip with real (trusted) mouse events, answers the background worker's messages with scripted replies, and
// checks the field values. With --shots <dir> it also saves a PNG per state, in light and dark.
//   node test/e2e.mjs [--shots /some/dir]      (needs Node 22+ and Chrome; set CHROME=/path/to/chrome if it isn't in /Applications)
import { spawn } from 'node:child_process';
import { mkdtempSync, writeFileSync, mkdirSync, existsSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert';

const here = dirname(fileURLToPath(import.meta.url));
const shotsDir = process.argv.includes('--shots') ? process.argv[process.argv.indexOf('--shots') + 1] : null;
const chromePath = process.env.CHROME || ['/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', '/Applications/Chromium.app/Contents/MacOS/Chromium', '/Applications/Brave Browser.app/Contents/MacOS/Brave Browser', '/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge'].find(existsSync);
if (!chromePath) { console.log('SKIP: no Chromium browser found (set CHROME=...)'); process.exit(0); }
if (typeof WebSocket === 'undefined') { console.log('SKIP: needs Node 22+ (global WebSocket)'); process.exit(0); }
if (shotsDir) mkdirSync(shotsDir, { recursive: true });

const profile = mkdtempSync(join(tmpdir(), 'mydroid-e2e-'));
const child = spawn(chromePath, ['--headless=new', '--remote-debugging-port=0', `--user-data-dir=${profile}`, '--no-first-run', '--no-default-browser-check',
  '--disable-extensions', '--disable-sync', '--disable-background-networking', '--window-size=900,700', 'about:blank'], { stdio: 'ignore' });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function wsUrl() {
  const f = join(profile, 'DevToolsActivePort');
  for (let i = 0; i < 100; i++) { if (existsSync(f)) { const [port, path] = readFileSync(f, 'utf8').trim().split('\n'); return `ws://127.0.0.1:${port}${path}`; } await sleep(100); }
  throw new Error('browser did not start');
}

class Cdp {
  constructor(url) { this.id = 0; this.cbs = new Map(); this.ws = new WebSocket(url); this.ready = new Promise((r) => (this.ws.onopen = r));
    this.ws.onmessage = (e) => { const m = JSON.parse(e.data); if (m.id && this.cbs.has(m.id)) { this.cbs.get(m.id)(m); this.cbs.delete(m.id); } }; }
  send(method, params = {}, sessionId) { return new Promise((res, rej) => { const id = ++this.id; this.cbs.set(id, (m) => (m.error ? rej(new Error(method + ': ' + m.error.message)) : res(m.result))); this.ws.send(JSON.stringify({ id, method, params, sessionId })); }); }
}

let cdp, sid, failures = 0, ran = 0;
const ev = async (expr) => { const r = await cdp.send('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise: true }, sid); if (r.exceptionDetails) throw new Error(r.exceptionDetails.text + ' ' + (r.exceptionDetails.exception?.description || '')); return r.result.value; };
const until = async (expr, what, ms = 4000) => { const end = Date.now() + ms; while (Date.now() < end) { if (await ev(expr)) return; await sleep(40); } throw new Error('timed out waiting for ' + what); };
async function load(page, scheme) {
  await cdp.send('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: scheme }] }, sid);
  await cdp.send('Page.navigate', { url: 'file://' + join(here, 'fixtures.html') + '?page=' + page }, sid);
  await until(`document.readyState === 'complete' && window.__roots.length > 0 && window.__roots[0].querySelector('.wrap.on')`, 'the chip');
}
const chipText = () => ev(`window.__roots[0].querySelector('.wrap').innerText`);
async function clickChip(selector) {
  const r = await ev(`(() => { const b = window.__roots[0].querySelector(${JSON.stringify(selector)}); if (!b) return null; const q = b.getBoundingClientRect(); return { x: q.left + q.width / 2, y: q.top + q.height / 2 }; })()`);
  assert.ok(r, 'no ' + selector);
  for (const type of ['mousePressed', 'mouseReleased']) await cdp.send('Input.dispatchMouseEvent', { type, x: r.x, y: r.y, button: 'left', clickCount: 1 }, sid);
}
/** Nothing may overflow or clip: the chip fits its box and stays inside the viewport (long names get an ellipsis, not a wider chip). */
async function assertCompact(what) {
  const r = await ev(`(() => {
    const w = window.__roots[0].querySelector('.wrap'); const q = w.getBoundingClientRect();
    const bad = [...w.querySelectorAll('.chip, .pop, .item, .label, .t, .s')].filter((e) => e.scrollWidth > e.clientWidth + 1 && getComputedStyle(e).overflow === 'visible').length;
    const chip = w.querySelector('.chip').getBoundingClientRect();
    return { w: q.width, left: q.left, right: q.right, vw: innerWidth, bad, chipH: chip.height };
  })()`);
  assert.ok(r.w <= 321, `${what}: ${r.w}px wide`);
  assert.ok(r.left >= 0 && r.right <= r.vw, `${what}: outside the viewport`);
  assert.strictEqual(r.bad, 0, `${what}: overflowing text`);
  assert.ok(r.chipH <= 32, `${what}: chip is ${r.chipH}px tall (wrapped?)`);
}
async function shot(name, scheme) {
  if (!shotsDir) return;
  await sleep(350);                       // let the chip's entrance animation finish
  const { data } = await cdp.send('Page.captureScreenshot', { format: 'png', clip: { x: 0, y: 0, width: 900, height: 520, scale: 1.5 } }, sid);
  writeFileSync(join(shotsDir, `chip-${name}-${scheme}.png`), Buffer.from(data, 'base64'));
}
async function test(name, fn) { ran++; try { await fn(); console.log('ok  ' + name); } catch (e) { failures++; console.log('FAIL ' + name + '\n     ' + e.message); } }

try {
  cdp = new Cdp(await wsUrl()); await cdp.ready;
  const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
  sid = (await cdp.send('Target.attachToTarget', { targetId, flatten: true })).sessionId;
  await cdp.send('Page.enable', {}, sid); await cdp.send('Runtime.enable', {}, sid);
  await cdp.send('Emulation.setDeviceMetricsOverride', { width: 900, height: 700, deviceScaleFactor: 1, mobile: false }, sid);

  const stub = (body) => ev(`window.__stub = ${body}; 0`);
  const sent = () => ev('window.__sent');

  for (const scheme of ['light', 'dark']) {
    await test(`single field: chip appears, a trusted click fills and fires events (${scheme})`, async () => {
      await load('single', scheme);
      assert.match(await chipText(), /Fill from phone/);
      await shot('idle-single', scheme);
      await ev(`window.__events = []; for (const t of ['keydown','beforeinput','input','keyup','change']) document.getElementById('otp').addEventListener(t, () => window.__events.push(t)); 0`);
      await stub(`(m) => m.op === 'code' ? { ok: true, code: '482196', validFor: 22 } : m.op === 'status' ? { ok: true, connected: true, autofill: false } : { ok: true }`);
      await clickChip('button.go');
      await until(`window.__roots[0].querySelector('.wrap').innerText.includes('Filled')`, 'filled');
      assert.strictEqual(await ev(`document.getElementById('otp').value`), '482196');
      const events = await ev('window.__events');
      for (const t of ['keydown', 'beforeinput', 'input', 'keyup', 'change']) assert.ok(events.includes(t), 'missing ' + t);
      assert.match(await chipText(), /Always fill here/);
      await shot('filled', scheme);
    });

    await test(`split boxes: each box gets its digit (${scheme})`, async () => {
      await load('split', scheme);
      await shot('idle-split', scheme);
      await stub(`(m) => m.op === 'code' ? { ok: true, code: '135790', validFor: 22 } : { ok: true, connected: true, autofill: false }`);
      await clickChip('button.go');
      await until(`window.__roots[0].querySelector('.wrap').innerText.includes('Filled')`, 'filled');
      assert.deepStrictEqual(await ev(`[...document.querySelectorAll('.split input')].map(i => i.value)`), ['1', '3', '5', '7', '9', '0']);
    });

    await test(`Salesforce-like page is detected (${scheme})`, async () => {
      await load('salesforce', scheme);
      await shot('idle-salesforce', scheme);
    });

    await test(`approval waits, then denied offers Try again (${scheme})`, async () => {
      await load('single', scheme);
      await stub(`(m) => m.op === 'code' ? { ok: false, error: 'denied' } : { ok: true }`);
      await ev(`window.__stub = (m) => m.op === 'code' ? new Promise(() => {}) : { ok: true }; 0`);
      await clickChip('button.go');
      await until(`window.__roots[0].querySelector('.wrap').innerText.includes('Approve on your phone')`, 'waiting');
      await shot('working', scheme);
      await load('single', scheme);
      await stub(`(m) => m.op === 'code' ? { ok: false, error: 'denied' } : { ok: true }`);
      await clickChip('button.go');
      await until(`window.__roots[0].querySelector('.wrap').innerText.includes('Denied')`, 'denied');
      assert.strictEqual(await ev(`document.getElementById('otp').value`), '');
      await shot('denied', scheme);
      for (const [err, text] of [['timeout', 'Timed out'], ['locked', 'Phone locked'], ['offline', 'Phone not connected'], ['no_app', 'isn’t running'], ['no_host', 'Not set up']]) {
        await stub(`(m) => m.op === 'code' ? { ok: false, error: '${err}' } : { ok: true }`);
        await clickChip('button.act:not(.solid)');
        await until(`window.__roots[0].querySelector('.wrap').innerText.includes(${JSON.stringify(text)})`, err);
        await assertCompact(err);
        await shot('error-' + err, scheme);
      }
      // The longer explanation hides behind the (i) and opens as a small popover.
      assert.ok(!/Settings › Authenticator/.test(await chipText()), 'explanation is not inline');
      await clickChip('button.icb[aria-label="More info"]');
      await until(`window.__roots[0].querySelector('.pop:not([hidden])')`, 'info popover');
      assert.match(await chipText(), /Settings › Authenticator/);
      await assertCompact('info');
      await shot('info', scheme);
    });

    await test(`no match: link flow with a lookalike warning, then fill (${scheme})`, async () => {
      await load('single', scheme);
      await stub(`(m) => m.op === 'code' && !m.entryId ? { ok: false, error: 'no_match', domain: 'paypa1.com' }
        : m.op === 'code' ? { ok: true, code: '909090', validFor: 20 }
        : m.op === 'list' ? { ok: true, domain: 'paypa1.com', items: [{ id: 'p1', issuer: 'PayPal', account: 'me@example.com' }, { id: 'g1', issuer: 'GitHub', account: 'octo' }], lookalike: { summary: 'Looks like paypal.com, with a letter changed.' } }
        : m.op === 'link' ? { ok: true, domain: 'paypa1.com' } : { ok: true, autofill: false }`);
      await clickChip('button.go');
      await until(`window.__roots[0].querySelector('.wrap').innerText.includes('No account for this site')`, 'no match');
      await assertCompact('nomatch');
      await shot('nomatch', scheme);
      await clickChip('button.act.solid');
      await until(`window.__roots[0].querySelector('.item')`, 'picker');
      await assertCompact('picker');
      await shot('picker-lookalike', scheme);
      assert.match(await chipText(), /Looks like paypal\.com/);
      await clickChip('button.item');
      await until(`window.__roots[0].querySelector('.wrap').innerText.includes('may not be the real site')`, 'confirm');
      await assertCompact('confirm');
      await shot('confirm', scheme);
      assert.ok(!(await sent()).some((m) => m.op === 'link'), 'nothing linked before confirming');
      await clickChip('button.btn.danger');
      await until(`window.__roots[0].querySelector('.wrap').innerText.includes('Filled')`, 'filled after link');
      const link = (await sent()).find((m) => m.op === 'link');
      assert.deepStrictEqual([link.entryId, link.acknowledged], ['p1', true]);
      assert.strictEqual(await ev(`document.getElementById('otp').value`), '909090');
    });

    await test(`ambiguous: picks an account, then fills (${scheme})`, async () => {
      await load('single', scheme);
      await stub(`(m) => m.op === 'code' && m.entryId === 'b' ? { ok: true, code: '777777', validFor: 9 }
        : m.op === 'code' ? { ok: false, error: 'ambiguous', choices: [{ id: 'a', issuer: 'Okta', account: 'one@x.com' }, { id: 'b', issuer: 'Okta', account: 'two@x.com' }] } : { ok: true }`);
      await clickChip('button.go');
      await until(`window.__roots[0].querySelectorAll('.item').length === 2`, 'picker');
      await shot('ambiguous', scheme);
      await ev(`window.__roots[0].querySelectorAll('.item')[1].scrollIntoView(); 0`);
      const r = await ev(`(() => { const q = window.__roots[0].querySelectorAll('.item')[1].getBoundingClientRect(); return { x: q.left + 20, y: q.top + q.height / 2 }; })()`);
      for (const type of ['mousePressed', 'mouseReleased']) await cdp.send('Input.dispatchMouseEvent', { type, x: r.x, y: r.y, button: 'left', clickCount: 1 }, sid);
      await until(`document.getElementById('otp').value === '777777'`, 'filled');
    });
  }

  await test('long account names and a narrow window stay tidy', async () => {
    await load('single', 'light');
    await cdp.send('Emulation.setDeviceMetricsOverride', { width: 360, height: 700, deviceScaleFactor: 1, mobile: false }, sid);
    const long = 'someone.with.a.really.long.address.that.goes.on@a-very-long-company-domain-name.example.com';
    await stub(`(m) => m.op === 'code' ? { ok: false, error: 'ambiguous', choices: [{ id: 'a', issuer: 'An Identity Provider With A Very Long Name Indeed', account: '${long}' }, { id: 'b', issuer: 'Okta', account: 'two@x.com' }] } : { ok: true }`);
    await clickChip('button.go');
    await until(`window.__roots[0].querySelectorAll('.item').length === 2`, 'picker');
    await assertCompact('long names');
    await shot('long-names-narrow', 'light');
    await cdp.send('Emulation.setDeviceMetricsOverride', { width: 900, height: 700, deviceScaleFactor: 1, mobile: false }, sid);
  });

  await test('a script-made click does nothing (only trusted clicks count)', async () => {
    await load('single', 'light');
    await ev(`window.__sent.length = 0; window.__roots[0].querySelector('button.go').click(); 0`);
    await sleep(300);
    assert.ok(!(await sent()).some((m) => m.op === 'code'));
  });

  await test('auto-fill opt-in fills without a click, once', async () => {
    await cdp.send('Page.navigate', { url: 'about:blank' }, sid);
    await cdp.send('Page.addScriptToEvaluateOnNewDocument', { source: `window.__preStub = true;` }, sid);
    await cdp.send('Page.navigate', { url: 'file://' + join(here, 'fixtures.html') + '?page=single' }, sid);
    await until(`document.readyState === 'complete'`, 'load');
    // The stub is installed after load, so reload the content script's view by rescanning through a DOM change.
    await ev(`window.__stub = (m) => m.op === 'status' ? { ok: true, connected: true, autofill: true, domain: 'example.org' } : m.op === 'code' ? { ok: true, code: '314159', validFor: 20 } : { ok: true }; 0`);
    await ev(`document.getElementById('otp').remove(); document.querySelector('form').insertAdjacentHTML('afterbegin', '<input id="otp" name="otp" inputmode="numeric" maxlength="6" autocomplete="one-time-code">'); 0`);
    await until(`document.getElementById('otp').value === '314159'`, 'auto-fill');
    assert.strictEqual((await sent()).filter((m) => m.op === 'code').length, 1);
  });

  await test('a phone/ZIP page shows no chip', async () => {
    await cdp.send('Page.navigate', { url: 'file://' + join(here, 'fixtures.html') + '?page=phone' }, sid);
    await until(`document.readyState === 'complete'`, 'load');
    await sleep(700);
    assert.strictEqual(await ev(`window.__roots.length === 0 || !window.__roots[0].querySelector('.wrap.on')`), true);
  });
} catch (e) {
  failures++; console.log('ERROR ' + e.message);
} finally {
  try { child.kill(); } catch {}
}
console.log(`\n${ran - failures}/${ran} e2e checks passed`);
process.exit(failures ? 1 : 0);
