/*
 * Mydroid Authenticator: content script (PROTOCOL.md 14.3).
 *
 * Finds a one-time-code field, shows a small "Fill from phone" chip next to it (in a closed shadow root, so the site's CSS and
 * scripts can't touch it), and fills the code the phone approved. The site is decided by the background worker from this frame's
 * own address, never from anything the page says. Only a real click (event.isTrusted) starts a fill, unless the user turned
 * on auto-fill for this site. Nothing is logged.
 */
(function () {
  'use strict';
  if (window.__mydroidOtp) return;
  const D = window.MydroidDetector;
  if (!D || !chrome.runtime || !chrome.runtime.id) return;
  window.__mydroidOtp = true;

  // ---- Talking to the background worker ----------------------------------------------------------------------------

  function ask(msg) {
    return new Promise((resolve) => {
      try {
        if (!chrome.runtime || !chrome.runtime.id) { resolve({ ok: false, error: 'gone' }); return; }
        chrome.runtime.sendMessage(msg, (res) => {
          if (chrome.runtime.lastError || !res) resolve({ ok: false, error: 'no_app' });
          else resolve(res);
        });
      } catch (e) { resolve({ ok: false, error: 'gone' }); }
    });
  }

  // ---- Filling -----------------------------------------------------------------------------------------------------

  const inputValueSetter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;

  /** Sets the value the way the browser would, bypassing a framework's own setter, so React/Vue/Angular notice. */
  function setNative(el, value) {
    const own = Object.getOwnPropertyDescriptor(el, 'value');
    if (own && own.set && own.set !== inputValueSetter) { try { delete el.value; } catch (e) { /* keep own */ } }
    inputValueSetter.call(el, value);
  }

  function keyInit(ch) {
    const digit = /^[0-9]$/.test(ch);
    return { key: ch, code: digit ? 'Digit' + ch : '', keyCode: digit ? 48 + Number(ch) : 0, which: digit ? 48 + Number(ch) : 0, bubbles: true, cancelable: true, composed: true };
  }

  function fireKey(el, type, ch) { el.dispatchEvent(new KeyboardEvent(type, keyInit(ch))); }

  function fireInput(el, data) {
    try { el.dispatchEvent(new InputEvent('beforeinput', { inputType: 'insertText', data, bubbles: true, cancelable: true, composed: true })); } catch (e) { /* older engines */ }
    el.dispatchEvent(new InputEvent('input', { inputType: 'insertText', data, bubbles: true, composed: true }));
  }

  function fillOne(el, text) {
    el.focus({ preventScroll: true });
    const last = text.slice(-1);
    fireKey(el, 'keydown', last);
    fireKey(el, 'keypress', last);
    setNative(el, text);
    fireInput(el, text);
    fireKey(el, 'keyup', last);
    el.dispatchEvent(new Event('change', { bubbles: true }));
  }

  /** Fills one box or a row of single-digit boxes. Returns false if the page changed under us. */
  function fillTarget(target, code) {
    const inputs = target.inputs;
    if (!inputs.every((i) => i.isConnected)) return false;
    if (target.kind === 'split') {
      const digits = D.splitCode(code, inputs.length);
      digits.forEach((d, i) => fillOne(inputs[i], d));
      const lastBox = inputs[Math.min(digits.length, inputs.length) - 1];
      if (lastBox) lastBox.focus({ preventScroll: true });
    } else {
      fillOne(inputs[0], code);
    }
    return true;
  }

  // ---- The chip ----------------------------------------------------------------------------------------------------
  //
  // A compact pill, like a native AutoFill chip: an icon and a few words. Anything longer sits behind the small (i), and the
  // account picker and the link flow open as a small popover under the chip.

  const CSS = `
    :host { all: initial; }
    .wrap { position: fixed; z-index: 2147483647; left: 0; top: 0; display: none; width: max-content; max-width: min(320px, calc(100vw - 16px)); }
    .wrap.on { display: block; }
    .ui { --bg: #fff; --fg: #1d1d1f; --mute: #6e6e73; --bd: rgba(0,0,0,.13); --accent: #0b73c4; --accent-fg: #fff;
          --good: #1a8f3c; --bad: #d32f2f; --warn: #a86400; --row: rgba(0,0,0,.055); --hover: rgba(0,0,0,.09);
          --shadow: 0 4px 14px rgba(0,0,0,.14), 0 1px 2px rgba(0,0,0,.12);
          font: 13px/1.3 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, system-ui, sans-serif; color: var(--fg);
          -webkit-font-smoothing: antialiased; position: relative; }
    @media (prefers-color-scheme: dark) {
      .ui { --bg: #2b2c2f; --fg: #f2f2f4; --mute: #a3a3ab; --bd: rgba(255,255,255,.16); --accent: #4db3f0; --accent-fg: #04131c;
            --good: #4cd070; --bad: #ff7070; --warn: #ffb347; --row: rgba(255,255,255,.08); --hover: rgba(255,255,255,.14);
            --shadow: 0 4px 16px rgba(0,0,0,.5), 0 1px 2px rgba(0,0,0,.4); }
    }
    @keyframes pop { from { opacity: 0; transform: translateY(-3px); } to { opacity: 1; transform: none; } }
    @keyframes spin { to { transform: rotate(360deg); } }
    @media (prefers-reduced-motion: reduce) { .chip, .pop { animation: none !important; } .spin { animation-duration: 3s !important; } }
    button { font: inherit; color: inherit; background: none; border: 0; padding: 0; margin: 0; cursor: pointer; }
    button:focus-visible { outline: 2px solid var(--accent); outline-offset: 1px; border-radius: 6px; }
    .icon { width: 16px; height: 16px; flex: none; display: block; }
    .ok { color: var(--good); } .err { color: var(--bad); } .warn { color: var(--warn); } .brand { color: var(--accent); } .mute { color: var(--mute); }

    .chip { display: flex; align-items: center; gap: 6px; height: 30px; padding: 0 4px 0 9px; width: fit-content; max-width: 100%;
            background: var(--bg); border: 1px solid var(--bd); border-radius: 10px; box-shadow: var(--shadow); box-sizing: border-box; animation: pop .16s ease-out; }
    .chip > .icon, .chip > .spin { margin-right: 1px; }
    .label { font-weight: 550; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; min-width: 0; }
    .dot { color: var(--mute); }
    .go { display: inline-flex; align-items: center; gap: 7px; height: 100%; padding: 0 6px 0 0; font-weight: 550; white-space: nowrap; }
    .act { height: 22px; padding: 0 7px; border-radius: 6px; font-weight: 600; color: var(--accent); white-space: nowrap; }
    .act:hover, .icb:hover { background: var(--hover); }
    .act.solid { background: var(--accent); color: var(--accent-fg); }
    .act.solid:hover { background: var(--accent); filter: brightness(.93); }
    .icb { width: 22px; height: 22px; border-radius: 6px; display: inline-flex; align-items: center; justify-content: center; color: var(--mute); flex: none; }
    .icb .icon { width: 14px; height: 14px; }
    .spin { width: 13px; height: 13px; border-radius: 50%; border: 2px solid var(--row); border-top-color: var(--accent); animation: spin .8s linear infinite; flex: none; box-sizing: border-box; }

    .pop { position: relative; margin-top: 7px; width: 272px; max-width: 100%; padding: 10px; box-sizing: border-box; background: var(--bg);
           border: 1px solid var(--bd); border-radius: 12px; box-shadow: var(--shadow); animation: pop .16s ease-out; }
    .pop[hidden] { display: none; }
    .pop .t { font-weight: 600; font-size: 13px; line-height: 1.3; overflow-wrap: anywhere; }
    .pop .s { color: var(--mute); font-size: 12px; line-height: 1.4; margin-top: 3px; overflow-wrap: anywhere; }
    .note { display: flex; gap: 6px; align-items: flex-start; margin-top: 8px; padding: 7px 8px; border-radius: 8px; font-size: 12px; line-height: 1.35;
            background: color-mix(in srgb, var(--warn) 14%, transparent); color: var(--fg); overflow-wrap: anywhere; }
    .note .icon { width: 14px; height: 14px; margin-top: 1px; color: var(--warn); }
    .list { display: flex; flex-direction: column; gap: 3px; margin-top: 8px; max-height: 168px; overflow: auto; }
    .item { display: flex; flex-direction: column; align-items: flex-start; gap: 1px; width: 100%; text-align: left; padding: 6px 9px; border-radius: 8px; background: var(--row); min-width: 0; }
    .item:hover { background: var(--hover); }
    .item b { font-weight: 600; max-width: 100%; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .item span { color: var(--mute); font-size: 12px; max-width: 100%; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .acts { display: flex; gap: 6px; justify-content: flex-end; margin-top: 10px; }
    .btn { font-weight: 600; font-size: 12.5px; padding: 5px 11px; border-radius: 8px; background: var(--row); }
    .btn:hover { background: var(--hover); }
    .btn.danger { background: var(--bad); color: #fff; }
    .btn.danger:hover { background: var(--bad); filter: brightness(.93); }
  `;

  const SVG = 'http://www.w3.org/2000/svg';
  function icon(name, cls) {
    const paths = {
      key: 'M14.5 3a5.5 5.5 0 0 0-5.2 7.3L3 16.6V21h4.4v-2.2h2.2v-2.2h2.1l1.9-1.9A5.5 5.5 0 1 0 14.5 3Zm1.6 3.2a1.6 1.6 0 1 1 0 3.2 1.6 1.6 0 0 1 0-3.2Z',
      check: 'M9.5 16.2 5.3 12l-1.4 1.4 5.6 5.6L21 7.5 19.6 6z',
      warn: 'M12 2 1 21h22L12 2Zm1 15h-2v-2h2v2Zm0-4h-2V9h2v4Z',
      x: 'M18.3 5.7 12 12l6.3 6.3-1.4 1.4L10.6 13.4 4.3 19.7 2.9 18.3 9.2 12 2.9 5.7 4.3 4.3l6.3 6.3 6.3-6.3z',
      info: 'M12 2a10 10 0 1 0 0 20 10 10 0 0 0 0-20Zm1 15h-2v-6h2v6Zm0-8h-2V7h2v2Z',
      deny: 'M12 2a10 10 0 1 0 0 20 10 10 0 0 0 0-20Zm4.2 12.8-1.4 1.4L12 13.4l-2.8 2.8-1.4-1.4L10.6 12 7.8 9.2l1.4-1.4L12 10.6l2.8-2.8 1.4 1.4L13.4 12z',
    };
    const s = document.createElementNS(SVG, 'svg');
    s.setAttribute('viewBox', '0 0 24 24'); s.setAttribute('class', 'icon ' + (cls || '')); s.setAttribute('aria-hidden', 'true');
    const p = document.createElementNS(SVG, 'path'); p.setAttribute('d', paths[name]); p.setAttribute('fill', 'currentColor');
    s.appendChild(p);
    return s;
  }

  function h(tag, props, ...kids) {
    const e = document.createElement(tag);
    if (props) for (const k of Object.keys(props)) {
      if (k === 'class') e.className = props[k];
      else if (k === 'text') e.textContent = props[k];
      else if (k.startsWith('on')) e.addEventListener(k.slice(2), props[k]);
      else e.setAttribute(k, props[k]);
    }
    for (const kid of kids) if (kid) e.appendChild(typeof kid === 'string' ? document.createTextNode(kid) : kid);
    return e;
  }

  /** Short label, an icon colour, whether Retry makes sense, and the longer explanation behind the (i). */
  const ERRORS = {
    denied: ['Denied', 'deny', 'err', true, 'You denied it on your phone. Nothing was filled.'],
    timeout: ['Timed out', 'warn', 'warn', true, 'Your phone didn’t answer in time.'],
    locked: ['Phone locked', 'warn', 'warn', true, 'Unlock your phone, then retry.'],
    offline: ['Phone not connected', 'warn', 'warn', true, 'Check that your phone is on and on the same network.'],
    no_app: ['Mydroid isn’t running', 'warn', 'warn', true, 'Open Mydroid on your Mac.'],
    no_host: ['Not set up here', 'warn', 'warn', false, 'Mydroid › Settings › Authenticator › Set Up.'],
    bad_site: ['Needs a secure site', 'warn', 'warn', false, 'Codes only fill on https pages.'],
    gone: ['Reload this page', 'warn', 'warn', false, 'The extension was updated.'],
    failed: ['Couldn’t get a code', 'warn', 'warn', true, 'Something went wrong. Try again.'],
  };

  class Chip {
    constructor(onAction) {
      this.onAction = onAction;
      this.host = document.createElement('div');
      this.host.setAttribute('data-mydroid', '');
      this.root = this.host.attachShadow({ mode: 'closed' });
      this.wrap = h('div', { class: 'wrap' });
      this.root.append(h('style', { text: CSS }), this.wrap);
      this.targetInputs = [];
      this.timer = null;
      this.hideTimer = null;
      this.visible = false;
      this.onReposition = () => this.position();
    }

    mount() { if (!this.host.isConnected) (document.documentElement || document.body).appendChild(this.host); }

    /** Replace what is shown with `card` (an element) and keep it anchored to `inputs`. */
    render(card, inputs) {
      this.mount();
      clearTimeout(this.hideTimer);
      this.targetInputs = inputs || this.targetInputs;
      this.wrap.replaceChildren(card);
      this.wrap.classList.add('on');
      this.visible = true;
      this.position();
      if (!this.timer) {
        window.addEventListener('scroll', this.onReposition, true);
        window.addEventListener('resize', this.onReposition);
        this.timer = setInterval(this.onReposition, 400);   // layout shifts the page doesn't tell us about
      }
    }

    hide() {
      clearTimeout(this.hideTimer);
      this.visible = false;
      this.wrap.classList.remove('on');
      if (this.timer) {
        clearInterval(this.timer); this.timer = null;
        window.removeEventListener('scroll', this.onReposition, true);
        window.removeEventListener('resize', this.onReposition);
      }
    }

    hideLater(ms) { clearTimeout(this.hideTimer); this.hideTimer = setTimeout(() => this.hide(), ms); }

    position() {
      if (!this.visible || !this.targetInputs.length) return;
      let l = Infinity, t = Infinity, r = -Infinity, b = -Infinity;
      for (const el of this.targetInputs) {
        if (!el.isConnected) { this.hide(); return; }
        const q = el.getBoundingClientRect();
        if (q.width === 0 && q.height === 0) continue;
        l = Math.min(l, q.left); t = Math.min(t, q.top); r = Math.max(r, q.right); b = Math.max(b, q.bottom);
      }
      if (!isFinite(l)) return;
      const w = this.wrap.offsetWidth, hgt = this.wrap.offsetHeight;
      let top = b + 6;
      if (top + hgt > window.innerHeight - 6 && t - hgt - 6 > 6) top = t - hgt - 6;
      let left = Math.min(Math.max(8, l), Math.max(8, window.innerWidth - w - 8));
      top = Math.min(Math.max(6, top), Math.max(6, window.innerHeight - hgt - 6));
      this.wrap.style.transform = `translate(${Math.round(left)}px, ${Math.round(top)}px)`;
    }

    // ---- Pieces

    trusted(fn) { return (e) => { if (e.isTrusted) fn(e); }; }

    dismissButton() {
      return h('button', { type: 'button', class: 'icb', 'aria-label': 'Dismiss', title: 'Dismiss', onclick: this.trusted(() => this.onAction('dismiss')) }, icon('x'));
    }

    /** A text action inside the chip ("Retry", "Link…"). */
    act(text, action, solid, label) {
      return h('button', { type: 'button', class: 'act' + (solid ? ' solid' : ''), 'aria-label': label || text, onclick: this.trusted(action) }, text);
    }

    /** The pill: icon, label, then actions. `info` (a sentence) adds an (i) that opens it in a small popover under the chip. */
    shell(role, parts, info, pop) {
      const ui = h('div', { class: 'ui' });
      const chip = h('div', { class: 'chip', role: role || 'status', 'aria-live': role === 'alert' ? 'assertive' : 'polite' }, ...parts);
      const detail = info ? h('div', { class: 'pop', hidden: '', role: 'note' }, h('div', { class: 's', style: 'margin-top:0', text: info })) : null;
      if (info) {
        const btn = h('button', { type: 'button', class: 'icb', 'aria-label': 'More info', title: 'More info', 'aria-expanded': 'false',
          onclick: this.trusted(() => {
            const open = detail.hasAttribute('hidden');
            if (open) detail.removeAttribute('hidden'); else detail.setAttribute('hidden', '');
            btn.setAttribute('aria-expanded', String(open));
            this.position();
          }) }, icon('info'));
        chip.insertBefore(btn, chip.lastChild);   // before the dismiss button
      }
      ui.append(chip);
      if (pop) ui.append(pop);
      if (detail) ui.append(detail);
      return ui;
    }

    // ---- States

    idle() {
      const go = h('button', { type: 'button', class: 'go', 'aria-label': 'Fill code from your phone', onclick: this.trusted(() => this.onAction('fill')) },
        icon('key', 'brand'), 'Fill from phone');
      return this.shell('group', [go, this.dismissButton()]);
    }

    working(text) {
      return this.shell('status', [h('div', { class: 'spin', 'aria-hidden': 'true' }), h('span', { class: 'label', text: text || 'Approve on your phone…' }), this.dismissButton()]);
    }

    filled(autofillOn) {
      const parts = [icon('check', 'ok'), h('span', { class: 'label', text: 'Filled' })];
      if (!autofillOn) parts.push(this.act('Always fill here', () => this.onAction('autofill-on'), false, 'Always fill on this site'));
      parts.push(this.dismissButton());
      return this.shell('status', parts);
    }

    autofillSet() {
      return this.shell('status', [icon('check', 'ok'), h('span', { class: 'label', text: 'Auto-fill on' }), this.dismissButton()],
        'Asks as soon as the field appears. You still approve on your phone.');
    }

    error(kind, retry) {
      const [label, ic, cls, canRetry, info] = ERRORS[kind] || ERRORS.failed;
      const parts = [icon(ic, cls), h('span', { class: 'label', text: label })];
      if (retry !== false && canRetry) parts.push(h('span', { class: 'dot', 'aria-hidden': 'true', text: '·' }), this.act('Retry', () => this.onAction('fill')));
      if (kind === 'no_host') parts.push(this.act('Set Up', () => this.onAction('options'), true));
      parts.push(this.dismissButton());
      return this.shell('alert', parts, info);
    }

    noMatch(domain) {
      return this.shell('alert', [icon('key', 'warn'), h('span', { class: 'label', text: 'No account for this site' }),
        this.act('Link…', () => this.onAction('link'), true, 'Link this site to an account'), this.dismissButton()],
        `${domain} isn’t linked to an account yet.`);
    }

    /** The account picker: a chip, with the list in a popover under it. */
    picker(title, rows, onPick, lookalike) {
      const list = h('div', { class: 'list', role: 'list' });
      for (const r of rows) {
        list.appendChild(h('button', { type: 'button', class: 'item', role: 'listitem', 'aria-label': `${r.issuer || 'Account'}, ${r.account || ''}`,
          onclick: this.trusted(() => onPick(r)) }, h('b', { text: r.issuer || 'Account' }), h('span', { text: r.account || '' })));
      }
      const note = lookalike ? h('div', { class: 'note', role: 'alert' }, icon('warn'), h('span', { text: lookalike.summary })) : null;
      const pop = h('div', { class: 'pop', role: 'group', 'aria-label': title },
        h('div', { class: 't', text: title }),
        note,
        rows.length ? list : h('div', { class: 's', text: 'No accounts on your phone' }),
        h('div', { class: 'acts' }, h('button', { type: 'button', class: 'btn', onclick: this.trusted(() => this.onAction('dismiss')) }, 'Cancel')));
      return this.shell('group', [icon('key', 'brand'), h('span', { class: 'label', text: 'Choose account' }), this.dismissButton()], null, pop);
    }

    confirm(domain, row, lookalike) {
      const pop = h('div', { class: 'pop', role: 'alertdialog', 'aria-label': 'Confirm link' },
        h('div', { class: 't', text: `${domain} may not be the real site` }),
        h('div', { class: 's', text: lookalike.summary }),
        h('div', { class: 'acts' },
          h('button', { type: 'button', class: 'btn', onclick: this.trusted(() => this.onAction('dismiss')) }, 'Cancel'),
          h('button', { type: 'button', class: 'btn danger', onclick: this.trusted(() => this.onAction('confirm-link', row)) }, 'Link anyway')));
      return this.shell('alert', [icon('warn', 'err'), h('span', { class: 'label', text: 'Check this site' }), this.dismissButton()], null, pop);
    }
  }

  // ---- Controller --------------------------------------------------------------------------------------------------

  let current = null;           // the best code field on the page
  let busy = false;
  let dismissedFor = null;      // the field set the user closed the chip for
  let autoTried = new WeakSet();
  let lastDomain = '';
  let knownAutofill = null;
  let pageTextAt = 0, pageTextCache = '';

  const chip = new Chip((action, arg) => { onAction(action, arg).catch(() => {}); });

  function pageText() {
    const now = Date.now();
    if (now - pageTextAt > 1500) {
      pageTextAt = now;
      try { pageTextCache = (document.body && document.body.innerText || '').slice(0, 6000); } catch (e) { pageTextCache = ''; }
    }
    return pageTextCache;
  }

  function sameTarget(a, b) {
    return a && b && a.kind === b.kind && a.inputs.length === b.inputs.length && a.inputs.every((el, i) => el === b.inputs[i]);
  }

  function rescan() {
    if (!document.querySelector('input')) { current = null; chip.hide(); return; }
    const found = D.findOtpFields(document, { pageText: pageText() });
    const best = found[0] || null;
    if (!best) { if (current) { current = null; chip.hide(); } return; }
    if (sameTarget(best, current)) return;
    current = best;
    if (dismissedFor && sameTarget(dismissedFor, best)) return;
    chip.render(chip.idle(), best.inputs);
    maybeAutofill(best);
  }

  async function maybeAutofill(target) {
    if (autoTried.has(target.inputs[0]) || document.visibilityState !== 'visible') return;
    if (knownAutofill === null) {
      const st = await ask({ op: 'status' });
      knownAutofill = !!(st.ok && st.autofill);
      if (st.domain) lastDomain = st.domain;
    }
    if (!knownAutofill || !sameTarget(target, current)) return;
    autoTried.add(target.inputs[0]);
    start({});
  }

  async function start(opts) {
    if (busy || !current) return;
    busy = true;
    const target = current;
    chip.render(chip.working(), target.inputs);
    const res = await ask({ op: 'code', entryId: opts.entryId });
    busy = false;
    if (!sameTarget(target, current)) return;
    if (res.ok) {
      if (!fillTarget(target, String(res.code))) { chip.render(chip.error('failed'), target.inputs); return; }
      if (knownAutofill === null) { const st = await ask({ op: 'status' }); knownAutofill = !!(st.ok && st.autofill); }
      chip.render(chip.filled(knownAutofill), target.inputs);
      chip.hideLater(knownAutofill ? 2500 : 9000);
      return;
    }
    if (res.domain) lastDomain = res.domain;
    switch (res.error) {
      case 'no_match': chip.render(chip.noMatch(lastDomain || location.hostname), target.inputs); break;
      case 'ambiguous':
        chip.render(chip.picker('Which account?', res.choices || [], (row) => start({ entryId: row.id })), target.inputs); break;
      case 'cancelled': chip.hide(); break;
      default: chip.render(chip.error(res.error), target.inputs);
    }
  }

  async function linkFlow() {
    if (!current) return;
    const target = current;
    chip.render(chip.working('Asking your phone…'), target.inputs);
    const res = await ask({ op: 'list' });
    if (!res.ok) { chip.render(chip.error(res.error || 'failed'), target.inputs); return; }
    if (res.domain) lastDomain = res.domain;
    const domain = lastDomain || location.hostname;
    chip.render(chip.picker(`Link ${domain} to:`, res.items || [], (row) => pickForLink(row, res.lookalike, domain), res.lookalike), target.inputs);
  }

  async function pickForLink(row, lookalike, domain) {
    const target = current;
    if (!target) return;
    if (lookalike) { chip.render(chip.confirm(domain, row, lookalike), target.inputs); return; }
    await doLink(row, false);
  }

  async function doLink(row, acknowledged) {
    const target = current;
    if (!target) return;
    chip.render(chip.working('Linking…'), target.inputs);
    const res = await ask({ op: 'link', entryId: row.id, acknowledged });
    if (res.ok) { start({ entryId: row.id }); return; }
    if (res.error === 'lookalike' && res.lookalike) { chip.render(chip.confirm(res.domain || lastDomain || location.hostname, row, res.lookalike), target.inputs); return; }
    chip.render(chip.error(res.error || 'failed'), target.inputs);
  }

  async function onAction(action, arg) {
    switch (action) {
      case 'fill': return start({});
      case 'link': return linkFlow();
      case 'confirm-link': return doLink(arg, true);
      case 'autofill-on': {
        const res = await ask({ op: 'autofill', on: true });
        if (res.ok) { knownAutofill = true; if (current) chip.render(chip.autofillSet(), current.inputs); chip.hideLater(5000); }
        return;
      }
      case 'options': await ask({ op: 'open-options' }); return;
      case 'dismiss':
      default:
        dismissedFor = current; chip.hide();
    }
  }

  // ---- Usernames typed earlier in this tab ---------------------------------------------------------------------------

  let userTimer = null;
  function rememberFrom(el) {
    if (!(el instanceof HTMLInputElement)) return;
    if (D.findUsernameFields({ querySelectorAll: () => [el] }, { isVisible: () => true }).length !== 1) return;
    const v = D.cleanAccount(el.value);
    if (v) ask({ op: 'remember-user', user: v });
  }
  function scheduleRemember(e) {
    clearTimeout(userTimer);
    const el = e.target;
    userTimer = setTimeout(() => rememberFrom(el), 500);
  }
  document.addEventListener('input', scheduleRemember, true);
  document.addEventListener('change', (e) => rememberFrom(e.target), true);
  document.addEventListener('focusout', (e) => rememberFrom(e.target), true);
  document.addEventListener('submit', (e) => {
    const f = e.target;
    if (f && f.querySelectorAll) for (const el of f.querySelectorAll('input')) rememberFrom(el);
  }, true);

  // ---- Watching the page ---------------------------------------------------------------------------------------------

  let scanTimer = null;
  function scheduleScan() { clearTimeout(scanTimer); scanTimer = setTimeout(rescan, 250); }
  new MutationObserver(scheduleScan).observe(document.documentElement, { childList: true, subtree: true, attributes: true, attributeFilter: ['hidden', 'style', 'class', 'disabled', 'type'] });
  document.addEventListener('focusin', scheduleScan, true);
  document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible') scheduleScan(); });
  window.addEventListener('pageshow', scheduleScan);
  document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && chip.visible) { dismissedFor = current; chip.hide(); } }, true);
  scheduleScan();
})();
