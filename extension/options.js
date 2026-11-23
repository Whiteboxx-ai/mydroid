'use strict';
const $ = (id) => document.getElementById(id);
const STATES = {
  connected: ['good', 'Connected', ''],
  phone_offline: ['warn', 'Phone not connected', ''],
  no_app: ['bad', 'Mydroid isn’t running', 'Open Mydroid on your Mac.'],
  no_host: ['bad', 'Not set up for this browser', 'Mydroid › Settings › Authenticator › Set Up'],
};
async function check() {
  $('status').textContent = 'Checking…';
  const res = await chrome.runtime.sendMessage({ op: 'popup-status' });
  const s = STATES[res.state] || STATES.no_app;
  $('dot').className = 'dot ' + s[0];
  $('status').textContent = s[1];
  $('hint').textContent = s[2];
}
$('extid').textContent = chrome.runtime.id;
$('test').addEventListener('click', check);
check();
