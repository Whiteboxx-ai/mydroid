/*
 * Mydroid Authenticator: finding one-time-code fields (PROTOCOL.md 14.3).
 *
 * Pure DOM reading, no side effects, no chrome.* calls, so it runs in the page's content script and under Node
 * (test/detector.test.js). Everything takes the elements it needs; nothing here fills or sends anything.
 */
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.MydroidDetector = factory();
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  const THRESHOLD = 60;

  // Words that say "this is a verification code" on their own.
  const STRONG = /\b(otp|totp|hotp|mfa|2fa|tfa|two factor|two step|2 step|authenticator|authentication code|authenticate code|one time|onetime|verification code|verify code|verification|security code|passcode|sms code|text code|login code|sign in code|confirmation code|6 digit|six digit|digit code|auth code)\b/;
  // A bare "code" or "token" or "pin" is only a hint.
  const WEAK = /\b(code|token|pin)\b/;
  // Things that are numeric and code-like but are not a sign-in code.
  const NEGATIVE = /\b(zip|postal|postcode|post code|promo|promotion|coupon|voucher|gift|discount|referral|invite|invitation|captcha|search|phone|mobile|telephone|tel|country|area|card|cvv|cvc|csc|ssn|routing|iban|swift|isbn|sku|tracking|order|quantity|qty|amount|price|otp ?resend|resend)\b/;
  // Words on the page that say a code is being asked for.
  const PAGE_HINT = /(verification code|security code|authentication code|one[- ]time (?:code|password|passcode)|6[- ]digit code|six[- ]digit code|authenticator app|two[- ]factor|2[- ]step|two[- ]step|enter (?:the |your )?(?:code|verification)|we (?:sent|texted|emailed|have sent) (?:you )?(?:a |an )?(?:code|text|verification)|code (?:we )?sent|enter the \d[- ]digit)/i;

  const TEXTY = new Set(['', 'text', 'tel', 'number', 'password']);

  function norm(s) {
    return String(s == null ? '' : s)
      .replace(/([a-z])([A-Z])/g, '$1 $2')
      .replace(/[_\-.:\[\]\/#]+/g, ' ')
      .replace(/\s+/g, ' ')
      .toLowerCase()
      .trim();
  }

  function attr(el, name) {
    const v = el.getAttribute ? el.getAttribute(name) : null;
    return v == null ? '' : String(v);
  }

  /** The text of the field's label(s), or ''. Tolerates missing DOM features. */
  function labelText(el) {
    let out = '';
    try {
      if (el.labels && el.labels.length) for (const l of el.labels) out += ' ' + (l.textContent || '');
      const by = attr(el, 'aria-labelledby');
      if (by && el.ownerDocument && el.ownerDocument.getElementById) {
        for (const id of by.split(/\s+/)) {
          const n = el.ownerDocument.getElementById(id);
          if (n) out += ' ' + (n.textContent || '');
        }
      }
    } catch (e) { /* a label we can't read is just no label */ }
    return out.slice(0, 200);
  }

  function describe(el) {
    return {
      name: norm(attr(el, 'name')),
      id: norm(attr(el, 'id')),
      placeholder: norm(attr(el, 'placeholder')),
      aria: norm(attr(el, 'aria-label')),
      test: norm(attr(el, 'data-testid') || attr(el, 'data-test') || attr(el, 'data-qa') || attr(el, 'data-cy')),
      label: norm(labelText(el)),
      autocomplete: attr(el, 'autocomplete').toLowerCase().trim(),
      inputmode: attr(el, 'inputmode').toLowerCase(),
      type: (attr(el, 'type') || 'text').toLowerCase(),
      pattern: attr(el, 'pattern'),
      maxlength: parseInt(attr(el, 'maxlength'), 10),
    };
  }

  function defaultVisible(el) {
    try {
      if (el.hidden) return false;
      if (typeof el.getClientRects === 'function' && el.getClientRects().length === 0) return false;
      const w = el.ownerDocument && el.ownerDocument.defaultView;
      if (w && w.getComputedStyle) {
        const cs = w.getComputedStyle(el);
        if (cs.visibility === 'hidden' || cs.display === 'none') return false;
      }
      return true;
    } catch (e) { return true; }
  }

  function eligible(el, opts, allowEmail) {
    if (!el || String(el.tagName).toUpperCase() !== 'INPUT') return false;
    const type = (attr(el, 'type') || 'text').toLowerCase();
    if (!TEXTY.has(type) && !(allowEmail && type === 'email')) return false;
    if (el.disabled || el.readOnly) return false;
    return (opts.isVisible || defaultVisible)(el);
  }

  /**
   * How likely a single input is a one-time-code field, 0 to 100+. `pageHint` is whether the page's text asks for a code.
   * Returns {score, reasons}. Anything at or above THRESHOLD counts.
   */
  function scoreInput(el, pageHint) {
    const d = describe(el);
    const reasons = [];
    let score = 0;
    if (d.autocomplete.split(/\s+/).includes('one-time-code')) return { score: 100, reasons: ['autocomplete'] };
    // Fields that are clearly something else.
    if (/^(username|email|current-password|new-password|tel|tel-national|name|given-name|family-name|street-address|postal-code|cc-|bday|organization|country)/.test(d.autocomplete)) return { score: -100, reasons: ['autocomplete other'] };
    if (d.type === 'email') return { score: -100, reasons: ['email'] };

    const texts = [d.name, d.id, d.placeholder, d.aria, d.test, d.label].filter(Boolean);
    const joined = texts.join(' | ');
    const strong = STRONG.test(joined);
    if (strong) { score += 60; reasons.push('keyword'); }
    else if (WEAK.test(joined)) { score += 30; reasons.push('weak keyword'); }
    if (!strong && NEGATIVE.test(joined)) { score -= 70; reasons.push('negative keyword'); }

    if (d.inputmode === 'numeric' || d.inputmode === 'decimal' || d.type === 'tel' || d.type === 'number') { score += 12; reasons.push('numeric'); }
    if (/^(\[0-9\]|\\d|\[\\d\])/.test(d.pattern) && /\{?[4-8]\}?/.test(d.pattern)) { score += 15; reasons.push('pattern'); }
    if (d.maxlength >= 6 && d.maxlength <= 8) { score += 18; reasons.push('maxlength'); }
    else if (d.maxlength >= 4 && d.maxlength <= 5) { score += 8; }
    else if (d.maxlength > 10) { score -= 10; }
    if (pageHint) { score += 20; reasons.push('page'); }
    if (d.type === 'password' && !strong) { score -= 25; reasons.push('password type'); }
    return { score, reasons };
  }

  function parentOf(el, levels) {
    let n = el;
    for (let i = 0; i < levels && n; i++) n = n.parentElement;
    return n || null;
  }

  /** Four to eight one-character boxes next to each other: a split code. Returns arrays of inputs. */
  function findSplitGroups(inputs, opts, pageHint) {
    const singles = inputs.filter((el) => {
      if (!eligible(el, opts)) return false;
      const ml = parseInt(attr(el, 'maxlength'), 10);
      return ml === 1 || attr(el, 'size') === '1';
    });
    if (singles.length < 4) return [];
    const groups = [];
    const used = new Set();
    for (let level = 1; level <= 3; level++) {
      const byParent = new Map();
      for (const el of singles) {
        if (used.has(el)) continue;
        const p = parentOf(el, level);
        if (!p) continue;
        if (!byParent.has(p)) byParent.set(p, []);
        byParent.get(p).push(el);
      }
      for (const arr of byParent.values()) {
        if (arr.length < 4 || arr.length > 8) continue;
        // Short groups (4 or 5 boxes) need another reason to be a code: a keyword, numeric boxes, or the page asking.
        const evidence = arr.some((el) => {
          const d = describe(el);
          return d.autocomplete === 'one-time-code' || d.inputmode === 'numeric' || d.type === 'tel' || d.type === 'number' ||
            STRONG.test([d.name, d.id, d.aria, d.placeholder, d.label].join(' '));
        });
        if (arr.length >= 6 || evidence || pageHint) {
          groups.push(arr);
          arr.forEach((el) => used.add(el));
        }
      }
    }
    return groups;
  }

  function pageWantsCode(text) {
    return PAGE_HINT.test(String(text || '').slice(0, 6000));
  }

  /**
   * Finds the code fields on a page. `doc` needs `querySelectorAll('input')`.
   * opts: { pageText, isVisible }. Returns [{kind:'single'|'split', inputs:[...], anchor, score}] best first.
   */
  function findOtpFields(doc, opts) {
    opts = opts || {};
    const pageHint = pageWantsCode(opts.pageText != null ? opts.pageText : (doc.body && doc.body.innerText));
    const inputs = Array.from(doc.querySelectorAll('input'));
    const out = [];
    const taken = new Set();
    for (const g of findSplitGroups(inputs, opts, pageHint)) {
      g.forEach((el) => taken.add(el));
      out.push({ kind: 'split', inputs: g, anchor: g[0], score: 90 });
    }
    for (const el of inputs) {
      if (taken.has(el) || !eligible(el, opts)) continue;
      const { score } = scoreInput(el, pageHint);
      if (score >= THRESHOLD) out.push({ kind: 'single', inputs: [el], anchor: el, score });
    }
    return out.sort((a, b) => b.score - a.score);
  }

  /** Likely username or email fields (for remembering what was typed earlier in the tab). */
  function findUsernameFields(doc, opts) {
    opts = opts || {};
    const found = [];
    for (const el of Array.from(doc.querySelectorAll('input'))) {
      if (!eligible(el, opts, true)) continue;
      const d = describe(el);
      if (d.type === 'password' || d.type === 'number') continue;
      if (/^(username|email|webauthn)/.test(d.autocomplete) || d.type === 'email' ||
          /\b(user|username|userid|user id|email|e mail|login|login id|account|identifier|loginfmt|signin)\b/.test([d.name, d.id, d.aria, d.placeholder, d.label].join(' | '))) {
        if (scoreInput(el, false).score >= THRESHOLD) continue;   // a code field is never a username
        found.push(el);
      }
    }
    return found;
  }

  /** A value worth remembering as the account name: short, one line, no spaces-only. */
  function cleanAccount(v) {
    const s = String(v == null ? '' : v).trim();
    if (s.length < 2 || s.length > 254 || /[\r\n]/.test(s)) return '';
    return s;
  }

  /** The code cut into the right number of pieces for a split box group. */
  function splitCode(code, boxes) {
    const chars = Array.from(String(code));
    return chars.slice(0, boxes);
  }

  return { THRESHOLD, norm, scoreInput, findOtpFields, findUsernameFields, findSplitGroups, pageWantsCode, cleanAccount, splitCode };
});
