'use strict';
// Run with: node test/detector.test.js   (Node 18+, no dependencies)
// Uses a tiny fake DOM (just what the detector reads), so it needs no browser.
const assert = require('assert');
const D = require('../detector.js');

class El {
  constructor(tag, attrs = {}, extra = {}) {
    this.tagName = tag.toUpperCase();
    this.attrs = attrs;
    this.parentElement = null;
    this.children = [];
    this.hidden = !!extra.hidden;
    this.disabled = !!extra.disabled;
    this.readOnly = !!extra.readOnly;
    this.labels = extra.label ? [{ textContent: extra.label }] : [];
    this.textContent = extra.text || '';
  }
  getAttribute(n) { return Object.prototype.hasOwnProperty.call(this.attrs, n) ? this.attrs[n] : null; }
  hasAttribute(n) { return Object.prototype.hasOwnProperty.call(this.attrs, n); }
  add(c) { c.parentElement = this; this.children.push(c); return c; }
}
const input = (attrs, extra) => new El('input', attrs, extra);

function page(build, text = '') {
  const body = new El('body');
  build(body);
  const all = [];
  (function walk(n) { if (n.tagName === 'INPUT') all.push(n); n.children.forEach(walk); })(body);
  return { doc: { querySelectorAll: (sel) => (sel === 'input' ? all : []), body: { innerText: text } }, opts: { pageText: text, isVisible: (e) => !e.hidden } };
}
const find = (p) => D.findOtpFields(p.doc, p.opts);
let ran = 0;
function test(name, fn) { fn(); ran++; console.log('ok  ' + name); }

test('single input with autocomplete=one-time-code', () => {
  const p = page((b) => b.add(input({ type: 'text', autocomplete: 'one-time-code' })));
  const r = find(p);
  assert.strictEqual(r.length, 1); assert.strictEqual(r[0].kind, 'single'); assert.ok(r[0].score >= 100);
});

test('single OTP-like input (name, numeric, maxlength 6)', () => {
  const p = page((b) => b.add(input({ type: 'text', name: 'otp', inputmode: 'numeric', maxlength: '6' })));
  const r = find(p);
  assert.strictEqual(r.length, 1); assert.ok(r[0].score >= D.THRESHOLD);
});

test('camelCase and underscore names: verificationCode, login_totp_code, mfa-token', () => {
  for (const name of ['verificationCode', 'login_totp_code', 'mfa-token', 'twoFactorCode', 'authenticatorCode']) {
    const r = find(page((b) => b.add(input({ type: 'text', name }))));
    assert.strictEqual(r.length, 1, name);
  }
});

test('split code: six one-character boxes in one container', () => {
  const p = page((b) => { const row = b.add(new El('div')); for (let i = 0; i < 6; i++) row.add(input({ type: 'text', maxlength: '1', inputmode: 'numeric' })); });
  const r = find(p);
  assert.strictEqual(r.length, 1); assert.strictEqual(r[0].kind, 'split'); assert.strictEqual(r[0].inputs.length, 6);
  assert.strictEqual(r[0].anchor, r[0].inputs[0]);
});

test('split code: every box wrapped in its own div', () => {
  const p = page((b) => { const row = b.add(new El('div')); for (let i = 0; i < 6; i++) row.add(new El('div')).add(input({ type: 'tel', maxlength: '1' })); });
  const r = find(p);
  assert.strictEqual(r.length, 1); assert.strictEqual(r[0].kind, 'split'); assert.strictEqual(r[0].inputs.length, 6);
});

test('split code: 4 plain boxes need a hint; with the page asking for a code they count', () => {
  const build = (b) => { const row = b.add(new El('div')); for (let i = 0; i < 4; i++) row.add(input({ type: 'text', maxlength: '1' })); };
  assert.strictEqual(find(page(build, 'Enter your details')).length, 0);
  assert.strictEqual(find(page(build, 'Enter the verification code we sent you')).length, 1);
});

test('Salesforce-like verification page', () => {
  const p = page((b) => {
    const f = b.add(new El('form'));
    f.add(input({ type: 'text', id: 'username', name: 'username', autocomplete: 'username' }, { hidden: true }));
    f.add(input({ type: 'text', id: 'emc', name: 'emc', placeholder: 'Verification Code', autocomplete: 'off' }, { label: 'Verification Code' }));
    f.add(input({ type: 'checkbox', id: 'rememberUn' }));
  }, 'Verify Your Identity. We sent a verification code to your email. Enter the code below.');
  const r = find(p);
  assert.strictEqual(r.length, 1); assert.strictEqual(r[0].anchor.getAttribute('id'), 'emc');
});

test('a field labelled "Mobile verification code" is a code despite "mobile"', () => {
  const r = find(page((b) => b.add(input({ type: 'text', name: 'f1' }, { label: 'Mobile verification code' }))));
  assert.strictEqual(r.length, 1);
});

test('password-type field named otp counts, a plain password does not', () => {
  assert.strictEqual(find(page((b) => b.add(input({ type: 'password', name: 'otp', maxlength: '6' })))).length, 1);
  assert.strictEqual(find(page((b) => b.add(input({ type: 'password', name: 'password', autocomplete: 'current-password' })))).length, 0);
});

test('non-OTP numeric fields never trigger', () => {
  const cases = [
    { type: 'tel', name: 'phone', inputmode: 'numeric', maxlength: '10' },
    { type: 'text', name: 'zip', inputmode: 'numeric', maxlength: '5' },
    { type: 'text', name: 'postal_code', inputmode: 'numeric', maxlength: '6' },
    { type: 'number', name: 'quantity', min: '1' },
    { type: 'text', name: 'promo_code', maxlength: '8' },
    { type: 'text', name: 'coupon-code', inputmode: 'numeric', maxlength: '6' },
    { type: 'text', name: 'gift_card_code' },
    { type: 'text', name: 'cardnumber', inputmode: 'numeric', autocomplete: 'cc-number', maxlength: '19' },
    { type: 'text', name: 'cvc', inputmode: 'numeric', maxlength: '4' },
    { type: 'text', name: 'ssn', inputmode: 'numeric', maxlength: '9' },
    { type: 'text', name: 'search', maxlength: '6' },
    { type: 'tel', name: 'mobile', autocomplete: 'tel' },
    { type: 'email', name: 'email' },
    { type: 'text', name: 'username', autocomplete: 'username' },
    { type: 'text', name: 'q', inputmode: 'numeric', maxlength: '6' },
  ];
  for (const a of cases) assert.strictEqual(find(page((b) => b.add(input(a)))).length, 0, JSON.stringify(a));
});

test('a numeric 6-digit field on a page that talks about a code still needs more than numeric+maxlength alone', () => {
  const r = find(page((b) => b.add(input({ type: 'text', name: 'x', inputmode: 'numeric', maxlength: '6' })), 'Welcome back'));
  assert.strictEqual(r.length, 0);
});

test('plain login page: username and password only', () => {
  const p = page((b) => { b.add(input({ type: 'email', name: 'email' })); b.add(input({ type: 'password', name: 'password' })); }, 'Sign in to your account');
  assert.strictEqual(find(p).length, 0);
});

test('hidden, disabled and read-only fields are ignored', () => {
  assert.strictEqual(find(page((b) => b.add(input({ name: 'otp' }, { hidden: true })))).length, 0);
  assert.strictEqual(find(page((b) => b.add(input({ name: 'otp' }, { disabled: true })))).length, 0);
  assert.strictEqual(find(page((b) => b.add(input({ name: 'otp' }, { readOnly: true })))).length, 0);
});

test('a split group is reported once, not also as single fields', () => {
  const p = page((b) => { const row = b.add(new El('div')); for (let i = 0; i < 6; i++) row.add(input({ type: 'text', maxlength: '1', name: 'otp' + i, autocomplete: 'one-time-code' })); });
  const r = find(p);
  assert.strictEqual(r.length, 1); assert.strictEqual(r[0].kind, 'split');
});

test('username fields: found, and a code field is never one', () => {
  const p = page((b) => {
    b.add(input({ type: 'email', name: 'loginfmt' }));
    b.add(input({ type: 'text', name: 'user_id' }));
    b.add(input({ type: 'text', name: 'otp', autocomplete: 'one-time-code' }));
    b.add(input({ type: 'password', name: 'password' }));
  });
  const u = D.findUsernameFields(p.doc, p.opts).map((e) => e.getAttribute('name'));
  assert.deepStrictEqual(u.sort(), ['loginfmt', 'user_id']);
});

test('helpers', () => {
  assert.strictEqual(D.cleanAccount('  me@work.com '), 'me@work.com');
  assert.strictEqual(D.cleanAccount('a'), '');
  assert.strictEqual(D.cleanAccount('x'.repeat(300)), '');
  assert.deepStrictEqual(D.splitCode('123456', 6), ['1', '2', '3', '4', '5', '6']);
  assert.deepStrictEqual(D.splitCode('12345678', 6), ['1', '2', '3', '4', '5', '6']);
  assert.strictEqual(D.norm('verificationCode_login-OTP'), 'verification code login otp');
  assert.ok(D.pageWantsCode('Enter the 6-digit code from your authenticator app'));
  assert.ok(!D.pageWantsCode('Add to cart'));
});

console.log(`\n${ran} detector tests passed`);
