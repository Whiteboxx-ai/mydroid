'use strict';
const $ = (id) => document.getElementById(id);
function done() { $('ask').hidden = true; $('done').hidden = false; }
// The request runs first thing in the click handler: Chrome only allows it from a direct click.
$('enable').addEventListener('click', () => { MydroidAccess.enableAll().then((ok) => { if (ok) done(); }); });
$('later').addEventListener('click', () => window.close());
MydroidAccess.state(null).then((s) => { if (s.all) done(); });
