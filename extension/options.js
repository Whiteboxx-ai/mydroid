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
async function where() {
  const s = await MydroidAccess.state(null);
  const granted = ((await chrome.permissions.getAll()).origins || []).length;
  $('where').textContent = s.all ? 'On for all sites.' : granted ? 'On for the sites you chose.' : 'Off. Use the toolbar button on a site, or allow all sites.';
  $('enableall').hidden = s.all;
  $('turnoff').hidden = !granted;
}
// The request must run first in the click handler.
$('enableall').addEventListener('click', () => { MydroidAccess.enableAll().then(where); });
$('turnoff').addEventListener('click', () => { MydroidAccess.turnOff().then(where); });
where();
$('extid').textContent = chrome.runtime.id;
$('test').addEventListener('click', check);
check();
