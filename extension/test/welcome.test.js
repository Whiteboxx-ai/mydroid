'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const source = fs.readFileSync(path.join(__dirname, '..', 'welcome.js'), 'utf8');
const tick = () => new Promise((resolve) => setImmediate(resolve));
const elements = new Map();
const element = (id) => {
  if (!elements.has(id)) {
    elements.set(id, {
      dataset: {}, hidden: false, disabled: false, value: '',
      addEventListener(type, callback) { this[type] = callback; },
      showModal() { this.open = true; },
      focus() {},
    });
  }
  return elements.get(id);
};

let connectionState = 'no_host';
let hasAllSites = false;
let requests = 0;
const accessEvent = () => ({ addListener(callback) { this.listener = callback; } });
const onAdded = accessEvent();
const onRemoved = accessEvent();

vm.runInNewContext(source, {
  document: { getElementById: element },
  window: { addEventListener() {} },
  chrome: {
    runtime: { sendMessage: async () => ({ state: connectionState }) },
    permissions: { onAdded, onRemoved },
  },
  MydroidAccess: {
    state: async () => ({ all: hasAllSites }),
    enableAll() {
      requests++;
      return Promise.resolve(hasAllSites);
    },
  },
});

(async () => {
  await tick();
  assert.equal(element('mac-status').textContent, 'Browser setup needed');
  assert.equal(element('connection-help').hidden, false);
  assert.equal(requests, 0, 'Loading the page does not request site access');

  connectionState = 'phone_offline';
  await element('retry').click();
  assert.equal(element('mac-status').dataset.ready, 'true');
  assert.equal(element('phone-status').textContent, 'Phone not connected');

  connectionState = 'connected';
  await element('retry').click();
  assert.equal(element('phone-status').dataset.ready, 'true');
  assert.equal(element('connection-help').hidden, true);

  element('enable').click();
  await tick();
  assert.equal(requests, 1);
  assert.equal(element('scope').hidden, false, 'Declining leaves site access optional');
  hasAllSites = true;
  await onAdded.listener();
  assert.equal(element('scope').hidden, true);
  hasAllSites = false;
  await onRemoved.listener();
  assert.equal(element('scope').hidden, false);

  element('try-fill').click();
  assert.equal(element('sample').open, true);
  element('fill').click();
  assert.equal(element('sample-code').value, '');
  element('approve').click();
  assert.equal(element('sample-code').value, '281904');
  assert.equal(requests, 1, 'The sample does not request site access');
  console.log('Welcome connection, permission, and sample-fill checks passed');
})().catch((error) => { console.error(error); process.exitCode = 1; });
