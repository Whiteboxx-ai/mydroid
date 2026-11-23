/*
 * Where the fill chip may run. The extension asks for website access when the user clicks Enable; until then it can't see any page.
 * Each request has to run straight from a click handler (Chrome drops the permission if anything is awaited first).
 * The background worker watches the grant and registers the content script for exactly the sites that were allowed.
 */
'use strict';
window.MydroidAccess = (function () {
  const ALL = ['https://*/*'];
  const originFor = (host) => (host === 'localhost' || host === '127.0.0.1' ? 'http://' : 'https://') + host + '/*';

  async function state(host) {
    const all = await chrome.permissions.contains({ origins: ALL });
    const here = host ? await chrome.permissions.contains({ origins: [originFor(host)] }) : false;
    return { all, here: all || here };
  }
  async function turnOff() {
    const granted = (await chrome.permissions.getAll()).origins || [];
    if (granted.length) await chrome.permissions.remove({ origins: granted });
  }
  return {
    state,
    enableAll: () => chrome.permissions.request({ origins: ALL }),
    enableHere: (host) => chrome.permissions.request({ origins: [originFor(host)] }),
    turnOff,
  };
})();
