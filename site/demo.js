// The moment where Intention is seen acting: you say a few words, the mark listens, and what you
// meant lands at the caret in one insertion, the way the Mac app inserts it. demo.css draws it.
//
// Contract. An element with data-replay holds [data-mark] (the small mark before what was said),
// [data-said] (the spoken words), [data-landed] (what landed in the window) and [data-caret] (the
// caret, whose first child is the dot above it). The words come from the page, so the HTML alone
// is the finished moment; this script puts it at rest when it starts, plays it once when it
// scrolls into view, and again whenever the mark is pressed. With reduced motion it leaves the
// finished moment in place and a press cuts between the states without tweening.
//
// The root's data-demo says where the play is (rest, listening, writing, done), and each change
// is announced as a "demo:state" event with { state } in its detail. The mark listens as the moon
// when the closest [data-light] is night. On a fresh visit the page opens with app.js's intro over
// it, so the first play waits for that intro's "intro:done".
(() => {
  const still = matchMedia('(prefers-reduced-motion: reduce)');
  const here = document.currentScript?.src || location.href;
  const ART = { sun: new URL('assets/sun@3x.webp', here).href, moon: new URL('assets/moon@3x.webp', here).href };

  // The mark's motion is the app's (SunDotView.swift). On open it rises on
  // SunDotView's spring (mass 1, stiffness 520, damping 26) from 36 percent of its size, peaking
  // at 107 percent at 168 ms. While listening it breathes on a 2.4 s cosine; on let go it eases
  // to 80 percent over 300 ms and breathes once while writing; it lands back to the page's own
  // resting mark over 260 ms, the mark taking over in the last 110, so the demo rests and ends on
  // the same mark with JavaScript and without it.
  // REST is the resting mark's size over the listening sun's. The app's mark grows about 2.8 times;
  // on a phone that is a large disc beside a short line, so under 600 px it grows about 1.7 times
  // and stays a small mark. measure() picks it; the spring, the mix and the sun's box all read it.
  const REST_WIDE = 0.36, REST_PHONE = 0.6, PEAK_K = 520, PEAK_C = 26;
  const phone = matchMedia('(max-width: 599px)');
  let REST = phone.matches ? REST_PHONE : REST_WIDE;
  const OPEN_WORDS = 0.32;   // the first word comes once the sun has opened
  const FADE = 0.12;         // each word fades in
  const BEAT = 0.4;          // after the last word, before letting go
  const LET_GO = 0.3;
  const WRITE = 0.8;
  const BREATH = 1.6;        // one working breath, 100 to 90 percent of the writing size and back
  const INSERT = 0.16;       // the whole text fades in at once
  const LAND = 0.26, MARK_FROM = 0.15;
  const AGAIN_FROM = 0.08, AGAIN = 0.36;
  const CARET_WORK = 1.5;    // the caret's dot while Intention writes
  const INTRO_BEAT = 500;    // ms between the end of the hero's intro and a first play under it
  const DISC = 110 / 160;    // the painting's disc across its image (the live site's sun and moon)
  const AGAIN_GAP = 3, AGAIN_HALF = 5.5;  // px between the mark and the arrow; the arrow's half width

  const W0 = Math.sqrt(PEAK_K), Z = PEAK_C / (2 * W0), WD = W0 * Math.sqrt(1 - Z * Z);
  const spring = t => 1 + (REST - 1) * Math.exp(-Z * W0 * t) * (Math.cos(WD * t) + (Z * W0 / WD) * Math.sin(WD * t));
  const clamp = x => (x < 0 ? 0 : x > 1 ? 1 : x);
  const inOut = x => (x <= 0 ? 0 : x >= 1 ? 1 : x < 0.5 ? 4 * x * x * x : 1 - Math.pow(-2 * x + 2, 3) / 2);
  const out = x => 1 - Math.pow(1 - clamp(x), 3);
  const mix = (a, b, k) => a + (b - a) * k;
  const cosine = (u, period) => 0.5 - 0.5 * Math.cos(2 * Math.PI * u / period);

  // The replay arrow, in the pen of the hero's drawn arrow: a small clockwise arc, open at the
  // upper right, its head at the top. Drawn about its own centre, in px; it sits beside the mark.
  const AGAIN_SVG = '<svg class="demo-again" viewBox="-7 -7 14 14" aria-hidden="true">'
    + '<path d="M3.17 3.17 C2.7 3.35 1.26 4.17 0.32 4.21 C-0.63 4.25 -1.73 3.94 -2.51 3.41 C-3.3 2.87 -4.13 1.93 -4.39 1 C-4.65 0.08 -4.54 -1.31 -4.08 -2.16 C-3.61 -3 -2.51 -3.79 -1.6 -4.09 C-0.69 -4.39 0.49 -4.27 1.38 -3.95 C2.27 -3.63 3.34 -2.46 3.74 -2.16"/>'
    + '<path d="M3.37 -4.94 L4.06 -1.92 L1.06 -1.88"/></svg>';

  // Wrap each spoken word in a span so it can appear on its own. Text inside the mark or in
  // screen-reader-only text is left alone.
  function splitWords(said) {
    const walker = document.createTreeWalker(said, NodeFilter.SHOW_TEXT, {
      acceptNode: node => (node.parentElement.closest('[data-mark], .sr-only') ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT),
    });
    const nodes = [];
    while (walker.nextNode()) nodes.push(walker.currentNode);
    const words = [];
    for (const node of nodes) {
      const parts = node.data.split(/(\s+)/);
      const frag = document.createDocumentFragment();
      for (const part of parts) {
        if (!part) continue;
        if (/^\s+$/.test(part)) { frag.append(part); continue; }
        const span = document.createElement('span');
        span.className = 'demo-word';
        span.textContent = part;
        frag.append(span);
        words.push(span);
      }
      node.replaceWith(frag);
    }
    return words;
  }

  // Gather what landed into one span, so it can be taken out and put back as one insertion.
  function gatherInk(landed, caret) {
    const ink = document.createElement('span');
    ink.className = 'demo-ink';
    const inside = landed.contains(caret);
    for (const node of [...landed.childNodes]) {
      if (node === caret || (node.nodeType === 1 && node.contains(caret))) continue;
      ink.append(node);
    }
    if (inside) caret.before(ink); else landed.append(ink);
    return ink;
  }

  function setup(root) {
    const said = root.querySelector('[data-said]');
    const landed = root.querySelector('[data-landed]');
    const caret = root.querySelector('[data-caret]');
    const mark = root.querySelector('[data-mark]');
    if (!said || !landed || !caret || !mark) return;

    const words = splitWords(said);
    if (!words.length) return;
    said.classList.add('demo-said');
    const ink = gatherInk(landed, caret);
    const caretDot = caret.firstElementChild;
    const isNight = () => root.closest('[data-light]')?.dataset.light === 'night';

    const button = document.createElement('button');
    button.type = 'button';
    button.className = 'demo-mark';
    button.setAttribute('aria-label', 'Play the example');
    mark.before(button);
    button.append(mark);
    button.insertAdjacentHTML('beforeend', `<span class="demo-sun" aria-hidden="true"><img alt="" decoding="async"><span class="demo-heart"></span></span>${AGAIN_SVG}`);
    const sun = button.querySelector('.demo-sun');
    const art = sun.querySelector('img');
    function light() {
      const night = isNight();
      sun.classList.toggle('is-moon', night);
      const src = night ? ART.moon : ART.sun;
      if (art.getAttribute('src') !== src) art.setAttribute('src', src);
    }
    light();
    const heart = button.querySelector('.demo-heart');
    const again = button.querySelector('.demo-again');

    let rest = 16, room = 4;
    // The button takes the mark's place in the line: its margins and alignment, and the mark's
    // size. The sun is the same painting as the mark, grown: at 36 percent it is the mark exactly.
    // room is how far past the mark the sun may reach towards the words; beyond that it grows
    // away from them, so it never covers a letter.
    function measure() {
      button.classList.add('is-measuring');
      button.style.margin = button.style.verticalAlign = '';
      const cs = getComputedStyle(mark);
      const margin = cs.margin, align = cs.verticalAlign;
      rest = mark.getBoundingClientRect().width || 16;
      room = Math.max(0, parseFloat(cs.marginRight) - 3);
      button.classList.remove('is-measuring');
      button.style.margin = margin;
      button.style.verticalAlign = align;
      button.style.setProperty('--demo-rest', `${rest}px`);
      REST = phone.matches ? REST_PHONE : REST_WIDE;
      button.style.setProperty('--demo-sun', `${(rest / REST).toFixed(2)}px`);
      // The replay arrow sits a few px left of the painted disc, in the margin beside the words. Where the
      // margin is too narrow (phones) it sits under the disc if the words fit on one line, and
      // otherwise under the whole line, at the disc's x, in the gap above the window.
      const box = button.getBoundingClientRect();
      const disc = rest * DISC / 2, reach = disc + AGAIN_GAP + AGAIN_HALF;
      const lines = new Set([...said.getClientRects()].map(r => Math.round(r.top))).size;
      const left = box.left + box.width / 2 - reach - AGAIN_HALF >= 8;
      const below = lines > 1 ? said.getBoundingClientRect().bottom - (box.top + box.height / 2) + AGAIN_GAP + AGAIN_HALF : reach;
      button.style.setProperty('--demo-again-x', left ? `${-reach}px` : '0px');
      button.style.setProperty('--demo-again-y', left ? '0px' : `${below.toFixed(1)}px`);
    }

    // When each word starts, at a speaking pace: a little longer for a longer word, and a pause
    // after a comma. The voice level follows the words, rising fast and falling slowly.
    const starts = [];
    let at = OPEN_WORDS;
    for (const w of words) {
      starts.push(at);
      const text = w.textContent;
      at += 0.2 + 0.034 * text.replace(/[^\p{L}\p{N}]/gu, '').length + (/[,.;:]$/.test(text) ? 0.16 : 0);
    }
    const voiceEnd = at;
    const letGo = starts.at(-1) + FADE + BEAT;
    const insert = letGo + LET_GO + BREATH;
    const done = insert + LAND;
    const end = done + AGAIN_FROM + AGAIN;
    const ends = starts.map((s, i) => Math.min(starts[i + 1] ?? voiceEnd, s + 0.5) - 0.04);

    function voice(t) {
      let v = 0;
      for (let i = 0; i < starts.length; i++) {
        const s = starts[i], e = ends[i];
        if (t < s) break;
        const up = 1 - Math.exp(-(Math.min(t, e) - s) / 0.14);
        v = Math.max(v, t < e ? up : up * Math.exp(-(t - e) / 0.7));
      }
      return v;
    }

    // Everything on screen at time t. With cut set (reduced motion) the same states, no tweens.
    function frame(t, cut) {
      const f = { words: [], q1: 0, q2: 0, sun: REST, sunOn: 0, heart: 0, ink: 0, inked: false, caret: 1, again: 0, turn: -70, mark: 1, state: 'rest' };
      if (t < 0) return f;
      f.mark = 0;
      f.sunOn = 1;
      for (let i = 0; i < words.length; i++) f.words.push(cut ? (t >= starts[i] ? 1 : 0) : clamp((t - starts[i]) / FADE));
      f.q1 = f.words[0];
      f.q2 = f.words.at(-1);
      if (t < letGo) {
        f.state = 'listening';
        const v = voice(t);
        f.sun = cut ? 1 : spring(t);
        const breath = cosine(t, 2.4) * (1 - Math.min(1, 2 * v));
        f.heart = cut ? 0.6 : clamp(0.32 + 0.12 * breath + 0.6 * Math.min(1, 1.3 * v)) * clamp(t / 0.12);
      } else if (t < insert) {
        f.state = 'writing';
        const u = t - letGo;
        const k = cut ? 1 : inOut(u / LET_GO);
        const b = cut || u < LET_GO ? 0 : cosine(u - LET_GO, BREATH);
        f.sun = mix(1, WRITE, k) * (1 - 0.1 * b);
        f.heart = cut ? 0.4 : mix(clamp(0.32 + 0.6 * Math.min(1, 1.3 * voice(t))), 0.26 + 0.34 * b, k);
        f.caret = mix(1, CARET_WORK, k) * (1 - 0.1 * b);
      } else {
        const u = t - insert;
        f.state = u < LAND ? 'writing' : 'done';
        f.inked = true;
        f.ink = cut ? 1 : clamp(u / INSERT);
        const k = cut ? 1 : inOut(u / LAND);
        f.sun = mix(WRITE, REST, k);
        f.heart = mix(0.26, 0, k);
        f.caret = mix(CARET_WORK, 1, k);
        f.mark = cut ? 1 : clamp((u - MARK_FROM) / (LAND - MARK_FROM));
        f.sunOn = f.mark < 1 ? 1 : 0;
        const a = cut ? (u >= LAND ? 1 : 0) : out((u - LAND - AGAIN_FROM) / AGAIN);
        f.again = a;
        f.turn = mix(-70, 0, a);
        if (u >= LAND) f.state = 'done';
      }
      return f;
    }

    // Write only what changed since the last frame.
    const last = new Map();
    const put = (el, key, value) => {
      if (last.get(el)?.[key] === value) return;
      if (!last.has(el)) last.set(el, {});
      last.get(el)[key] = value;
      if (key === 'hidden') el.hidden = value;
      else if (key.startsWith('--')) el.style.setProperty(key, value);
      else el.style[key] = value;
    };
    let state = '';
    function paint(f) {
      words.forEach((w, i) => put(w, 'opacity', String(+f.words[i]?.toFixed(3) || 0)));
      put(said, '--demo-q1', String(+f.q1.toFixed(3)));
      put(said, '--demo-q2', String(+f.q2.toFixed(3)));
      put(sun, 'opacity', String(f.sunOn));
      const reach = DISC / 2 * (rest / REST) * f.sun - rest / 2 - room;
      put(sun, 'transform', `translateX(${(reach > 0 ? -reach : 0).toFixed(2)}px) scale(${f.sun.toFixed(4)})`);
      put(heart, 'opacity', String(+f.heart.toFixed(3)));
      put(heart, 'transform', `scale(${(0.8 + 0.3 * f.heart).toFixed(4)})`);
      put(mark, 'opacity', String(+f.mark.toFixed(3)));
      put(ink, 'hidden', !f.inked);
      put(ink, 'opacity', String(+f.ink.toFixed(3)));
      if (caretDot) put(caretDot, 'transform', `scale(${f.caret.toFixed(4)})`);
      put(again, 'opacity', String(+f.again.toFixed(3)));
      put(again, 'transform', `rotate(${f.turn.toFixed(2)}deg)`);
      if (f.state !== state) {
        state = f.state;
        root.dataset.demo = state;
        root.dispatchEvent(new CustomEvent('demo:state', { detail: { state } }));
      }
    }

    // One requestAnimationFrame loop, running only while the demo plays. Time advances by frame,
    // capped, so a hidden tab picks up where it left off rather than skipping to the end.
    let raf = 0, t = 0, prev = 0, cut = false, played = false;
    function tick(now) {
      t += Math.min(0.05, (now - prev) / 1000);
      prev = now;
      if (cut) {
        paint(frame(t, true));
        if (t >= done) return stop();
      } else {
        paint(frame(t, false));
        if (t >= end) return stop();
      }
      raf = requestAnimationFrame(tick);
    }
    function stop() {
      cancelAnimationFrame(raf);
      raf = 0;
      played = true;
      button.setAttribute('aria-label', 'Play again');
    }
    function play() {
      cancelAnimationFrame(raf);
      light();
      measure();
      cut = still.matches;
      t = -1 / 60;
      paint(frame(-1, cut));
      prev = performance.now();
      raf = requestAnimationFrame(tick);
    }
    // Stop wherever the play is and show time t; for checks and renders.
    function seek(time) {
      cancelAnimationFrame(raf);
      raf = 0;
      light();
      measure();
      t = time;
      paint(frame(time, still.matches));
    }

    button.addEventListener('click', play);
    measure();
    let width = innerWidth;
    addEventListener('resize', () => { if (!raf && innerWidth !== width) { width = innerWidth; measure(); } }, { passive: true });

    // At rest until the demo arrives, then once; with reduced motion, the finished moment.
    function settle() {
      if (raf) return;
      paint(frame(still.matches || played ? end : -1, true));
    }
    settle();
    still.addEventListener('change', settle);

    const cell = [...root.querySelectorAll('*')].reverse().find(el => el.contains(said) && el.contains(landed)) || root;
    const first = () => { if (!still.matches && !played && !raf) play(); };
    if ('IntersectionObserver' in window) {
      const arrive = new IntersectionObserver(entries => {
        if (!entries.some(e => e.isIntersecting && e.intersectionRatio >= 0.6)) return;
        arrive.disconnect();
        if (!document.body.classList.contains('intro-running')) return first();
        // A short beat after the intro lets the eye land on the page before the play.
        document.addEventListener('intro:done', () => setTimeout(first, INTRO_BEAT), { once: true });
      }, { threshold: 0.6 });
      arrive.observe(cell);
    }

    root.intentionDemo = { play, seek, times: { letGo, insert, done, end } };
  }

  document.querySelectorAll('[data-replay]').forEach(setup);
})();
