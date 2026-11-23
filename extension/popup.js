'use strict';
const $ = (id) => document.getElementById(id);

const STATES = {
  connected: ['good', 'Connected', ''],
  phone_offline: ['warn', 'Phone not connected', ''],
  no_app: ['bad', 'Mydroid isn’t running', 'Open Mydroid on your Mac.'],
  no_host: ['bad', 'Not set up for this browser', 'Mydroid › Settings › Authenticator › Set Up'],
};

function show(state) {
  const s = STATES[state] || STATES.no_app;
  $('dot').className = 'dot ' + s[0];
  $('status').textContent = s[1];
  $('hint').textContent = s[2];
}

async function currentHost() {
  try {
    const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
    const u = new URL(tab.url);
    const local = u.hostname === 'localhost' || u.hostname === '127.0.0.1';
    return u.protocol === 'https:' || (u.protocol === 'http:' && local) ? u.hostname : null;
  } catch (e) { return null; }
}

(async function main() {
  $('options').addEventListener('click', () => chrome.runtime.openOptionsPage());
  const host = await currentHost();
  const res = await chrome.runtime.sendMessage({ op: 'popup-status', host });
  show(res.state);
  if (host && res.state === 'connected') {
    $('autorow').hidden = false;
    $('autohost').textContent = res.domain || host;
    $('auto').checked = !!res.autofill;
    $('auto').addEventListener('change', async (e) => {
      const r = await chrome.runtime.sendMessage({ op: 'popup-autofill', host, on: e.target.checked });
      if (!r.ok) e.target.checked = !e.target.checked;
    });
  }
})();
