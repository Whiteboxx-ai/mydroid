'use strict';

const $ = (id) => document.getElementById(id);
const connectionStates = {
  connected: ['Connected', 'Connected', ''],
  phone_offline: ['Connected', 'Phone not connected', 'Open Mydroid on Android and check that both devices are on the same Wi-Fi.'],
  no_app: ['Mydroid isn’t running', 'Waiting for Mydroid for Mac', 'Open Mydroid from the Applications folder.'],
  no_host: ['Browser setup needed', 'Waiting for Mydroid for Mac', 'On your Mac, open Mydroid → Settings → Authenticator and choose Set up next to this browser.'],
  unavailable: ['Connection check unavailable', 'Waiting for Mydroid for Mac', 'Check the connection again.'],
};

async function refresh() {
  if ($('retry').disabled) return;
  $('retry').disabled = true;
  try {
    const result = await chrome.runtime.sendMessage({ op: 'popup-status' }).catch(() => null);
    const [mac, phone, help] = connectionStates[result?.state] ?? connectionStates.unavailable;
    for (const [id, value] of [['mac-status', mac], ['phone-status', phone]]) {
      $(id).textContent = value;
      $(id).dataset.ready = String(value === 'Connected');
    }
    $('connection-help').textContent = help;
    $('connection-help').hidden = !help;
    $('connection-actions').hidden = !help;
  } finally {
    $('retry').disabled = false;
  }
}

function showAccess(enabled) {
  $('scope').hidden = enabled;
  $('access-status').hidden = !enabled;
  $('access-status').textContent = enabled ? 'Fill from phone is enabled on all HTTPS sites.' : '';
}

$('retry').addEventListener('click', refresh);
window.addEventListener('focus', refresh);
$('options').addEventListener('click', () => chrome.runtime.openOptionsPage());
$('enable').addEventListener('click', () => {
  // Chrome requires the permission request to start inside the user click.
  MydroidAccess.enableAll().then(showAccess).catch(() => {
    $('access-status').hidden = false;
    $('access-status').textContent = 'The browser couldn’t change site access. Try again or open extension settings.';
  });
});
chrome.permissions.onAdded.addListener(() => MydroidAccess.state(null).then(({ all }) => showAccess(all)));
chrome.permissions.onRemoved.addListener(() => MydroidAccess.state(null).then(({ all }) => showAccess(all)));

$('try-fill').addEventListener('click', () => {
  $('sample-code').value = '';
  $('sample-status').textContent = '';
  $('fill').hidden = false;
  $('approve').hidden = true;
  $('sample').showModal();
});
$('fill').addEventListener('click', () => {
  $('fill').hidden = true;
  $('approve').hidden = false;
  $('sample-status').textContent = 'Approve on your phone…';
  $('approve').focus();
});
$('approve').addEventListener('click', () => {
  $('sample-code').value = '281904';
  $('sample-status').textContent = 'Filled';
  $('approve').hidden = true;
  $('sample-code').focus();
});

MydroidAccess.state(null).then(({ all }) => showAccess(all));
refresh();
