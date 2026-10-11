// The staged demo. Every word, window and timing comes from scenes.json (embedded in index.html as
// #stage-scenes); nothing listens, calls a model or uses the network. Every frame is a pure function
// of time: live keys and the seek API both draw through frame(), so a take and a rendered video
// frame at the same time look the same. The contract is README.md.
(() => {
  'use strict';

  const DATA = JSON.parse(document.getElementById('stage-scenes').textContent);
  const SCENES = DATA.scenes, T = DATA.timing, A = DATA.assumptions;
  const reduce = matchMedia('(prefers-reduced-motion: reduce)');

  const stage = document.querySelector('.stage');
  const screen = stage.querySelector('.screen');
  const appName = stage.querySelector('[data-app]');
  const slip = stage.querySelector('[data-slip]');
  const wordsEl = stage.querySelector('[data-words]');
  const footEl = stage.querySelector('.foot');
  const dot = stage.querySelector('.foot-dot');
  const sun = stage.querySelector('.foot-sun');
  const help = stage.querySelector('[data-help]');
  const sections = Object.fromEntries([...stage.querySelectorAll('.scene')].map(s => [s.dataset.for, s]));
  const templates = {};
  stage.querySelectorAll('.scene-app').forEach(s => { templates[s.dataset.for] = s.querySelector('.win').innerHTML; });

  // ---- Fit the 1440x900 screen to the window ---------------------------------------------------
  // The screen is 900 points tall and 1440 to 1600 wide: it takes the window's aspect between 16:10
  // and 16:9 (so 1920x1080 fills edge to edge), then scales whole to fit.
  function fit() {
    const w = Math.round(Math.min(1600, Math.max(1440, 900 * innerWidth / innerHeight)));
    screen.style.setProperty('--w', w + 'px');
    screen.style.setProperty('--fit', Math.min(innerWidth / w, innerHeight / 900).toFixed(4));
  }
  addEventListener('resize', fit); fit();

  // ---- Small maths -------------------------------------------------------------------------------
  const clamp = x => (x < 0 ? 0 : x > 1 ? 1 : x);
  const mix = (a, b, k) => a + (b - a) * k;
  const easeOut = x => 1 - Math.pow(1 - clamp(x), 3);
  const easeInOut = x => { x = clamp(x); return x < .5 ? 4 * x * x * x : 1 - Math.pow(-2 * x + 2, 3) / 2; };
  const words = text => text.split(/\s+/).filter(Boolean);
  const plain = html => html.replace(/<br>/g, ' ').replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim();
  const still = () => reduce.matches;

  // ---- Schedules -----------------------------------------------------------------------------------
  // When each word arrives, when the key is let go, when the text lands and when the scene is done,
  // in seconds from the start of the play. `release` is when right Control was let go (null: the
  // Space path lets go on its own; Infinity: still held).
  function schedule(sc, release = null) {
    const n = words(sc.said).length;
    let wordAt = Array.from({ length: n }, (_, i) => T.firstWord + i * T.word);
    let letGo = wordAt[n - 1] + T.beat;
    if (release === Infinity) letGo = Infinity;
    else if (release != null) {
      const left = wordAt.filter(w => w > release).length;
      if (left) wordAt = wordAt.map((w, i) => (w > release ? release + T.flush * (i - (n - left) + 1) / left : w));
      letGo = left ? release + T.flush : Math.max(release, T.rise);
    }
    const insertAt = letGo + T.write;
    return { wordAt, letGo, insertAt, doneAt: insertAt + T.insert + T.land };
  }
  const playLength = sc => (sc.said ? schedule(sc).doneAt : sc.id === 'savings' ? T.count : 0);

  // ---- Drawing one app scene at play time u (null: ready, not yet played) -------------------------
  // Clipped panes keep no scroll offset, so a window's layout depends only on its content.
  const unscroll = el => el.querySelectorAll('*').forEach(n => { if (n.scrollTop || n.scrollLeft) { n.scrollTop = 0; n.scrollLeft = 0; } });
  function resetWindow(id) { if (templates[id] != null) { sections[id].querySelector('.win').innerHTML = templates[id]; sections[id].dataset.inserted = ''; } }
  function placeText(sc) {
    const s = sections[sc.id], box = s.querySelector('[data-insert]'), caret = s.querySelector('[data-caret]');
    box.innerHTML = sc.wrote;
    const spot = box.querySelector('[data-caret-here]');
    if (spot) { const holder = caret.parentElement; spot.replaceWith(caret); if (holder.classList.contains('stage-nt-line')) holder.remove(); }
    s.querySelector('.sk-field')?.classList.add('has-text');
    s.dataset.inserted = '1';
    unscroll(s);
  }
  let slipFor = null;
  function slipWordsFor(sc) {
    if (slipFor !== sc.id) {
      wordsEl.replaceChildren(...words(sc.said).flatMap((w, i) => {
        const span = document.createElement('span'); span.className = 'w'; span.textContent = w;
        return i ? [document.createTextNode(' '), span] : [span];
      }));
      slipFor = sc.id;
    }
    return [...wordsEl.querySelectorAll('.w')];
  }
  // The foot: the resting dot, or the listening sun at a scale and opacity.
  function drawFoot(sunScale, sunOpacity, dotOpacity) {
    // Sized, not scaled: a transform lets the compositor reuse an old raster, so a seeked frame could
    // depend on what was drawn before it.
    const px = (64 * sunScale).toFixed(2);
    sun.style.opacity = (sunOpacity * footAlpha).toFixed(3); sun.style.width = sun.style.height = px + 'px'; sun.style.margin = `${(-32 * sunScale).toFixed(2)}px 0 0 ${(-32 * sunScale).toFixed(2)}px`; dot.style.opacity = (dotOpacity * footAlpha).toFixed(3);
  }
  function drawScene(sc, u, sched) {
    const s = sections[sc.id];
    if (u == null) {                                   // ready
      if (s.dataset.inserted) resetWindow(sc.id);
      slip.style.opacity = '0'; drawFoot(.36, 0, 1); return 'ready';
    }
    const { wordAt, letGo, insertAt, doneAt } = sched;
    // Words, and the slip that holds them.
    const ws = slipWordsFor(sc);
    ws.forEach((w, i) => { w.style.opacity = clamp((u - wordAt[i]) / T.wordFade).toFixed(3); });
    const slipIn = clamp(u / 0.2), slipOut = 1 - clamp((u - insertAt - T.insert) / 0.2);
    slip.style.opacity = (Math.min(slipIn, slipOut) * footAlpha).toFixed(3);
    slip.style.transform = `translateY(${(6 * (1 - easeOut(u / 0.25))).toFixed(2)}px)`;
    // The text at the caret: one insertion with a short fade.
    if (u >= insertAt) { if (!s.dataset.inserted) placeText(sc); s.querySelector('[data-insert]').style.opacity = still() ? '1' : clamp((u - insertAt) / T.insert).toFixed(3); }
    else if (s.dataset.inserted) resetWindow(sc.id);
    // The sun: rises, breathes while listening, eases to 80% and breathes once while writing, lands.
    const landFrom = insertAt + T.insert;
    let scale = 1, op = 1, dotOp = 0;
    if (still()) { scale = u < landFrom ? 1 : .36; op = u < landFrom + T.land ? 1 : 0; dotOp = u < landFrom + T.land ? 0 : 1; }
    else if (u < T.rise) { const k = u / T.rise; scale = k < .48 ? mix(.36, 1.07, easeOut(k / .48)) : mix(1.07, 1, easeInOut((k - .48) / .52)); }
    else if (u < letGo) { scale = 1 - .06 * (.5 - .5 * Math.cos(2 * Math.PI * (u - T.rise) / 2.4)); }
    else if (u < landFrom) {
      const k = (u - letGo) / T.write, from = 1 - .06 * (.5 - .5 * Math.cos(2 * Math.PI * (letGo - T.rise) / 2.4));
      scale = k < .3 ? mix(from, .8, easeInOut(k / .3)) : .8 - .08 * Math.sin(Math.PI * clamp((k - .3) / .7));
    } else {
      const k = clamp((u - landFrom) / T.land);
      scale = mix(.8, .36, easeInOut(k)); op = 1 - easeInOut(k); dotOp = clamp((k - .58) / .42);
    }
    drawFoot(scale, op, dotOp);
    unscroll(s);
    return u < letGo ? 'listening' : u < doneAt ? 'writing' : 'done';
  }

  // ---- Time saved -----------------------------------------------------------------------------------
  // The same written words are timed both ways: typed at typingWPM and spoken at speakingWPM.
  function metrics() {
    return SCENES.filter(s => s.said).map(s => {
      const n = s.writtenWords ?? words(plain(s.wrote)).length;
      return { s, n, typeSec: n / A.typingWPM * 60, speakSec: n / A.speakingWPM * 60 };
    });
  }
  const savedSeconds = () => metrics().reduce((n, r) => n + r.typeSec - r.speakSec, 0);
  const clock = sec => { const r = Math.round(sec); return `${Math.floor(r / 60)}:${String(r % 60).padStart(2, '0')}`; };
  (function renderSavings() {
    const list = stage.querySelector('[data-rows]');
    list.innerHTML = `<li class="sv-head"><span></span><span>Written</span><span class="num">Typing · ${A.typingWPM} WPM</span><span class="num">Speaking · ${A.speakingWPM} WPM</span></li>` +
      metrics().map(r => `<li><span class="sv-ico" data-icon="${r.s.icon || ''}"></span><span>${r.s.label} <span class="faint">· ${r.n} words</span></span><span class="num">${clock(r.typeSec)}</span><span class="num faint">${clock(r.speakSec)}</span></li>`).join('');
    const rows = metrics(), n = rows.reduce((k, r) => k + r.n, 0);
    list.insertAdjacentHTML('beforeend', `<li class="sv-sum"><span></span><span>Total <span class="faint">· ${n} words</span></span><span class="num">${clock(n / A.typingWPM * 60)}</span><span class="num faint">${clock(n / A.speakingWPM * 60)}</span></li>`);
    list.querySelectorAll('[data-icon]').forEach(el => { if (el.dataset.icon) { const img = new Image(); img.alt = ''; img.src = el.dataset.icon; el.replaceWith(img); } });
  })();
  const totalEl = stage.querySelector('[data-total]');
  function drawSavings(u) {
    if (u == null) { totalEl.textContent = clock(0); return 'ready'; }
    totalEl.textContent = clock(savedSeconds() * (still() ? 1 : easeOut(u / T.count)));
    return u < T.count ? 'counting' : 'done';
  }

  // ---- One frame: scene i, `local` seconds since it was entered, play time u, previous scene -----
  // The scene fades in over T.swap from the one before it (or cuts, with no previous scene).
  let shownScene = null, footAlpha = 1;
  function frame(i, local, u, sched, prev) {
    const sc = SCENES[i];
    const k = prev == null || still() ? 1 : clamp(local / T.swap);
    for (const [id, el] of Object.entries(sections)) {
      const o = id === sc.id ? k : prev != null && id === SCENES[prev].id ? 1 - k : 0;
      el.style.opacity = o.toFixed(3); el.style.visibility = o > 0 ? 'visible' : 'hidden';
      const win = el.querySelector('.win'); if (win && id === sc.id) win.style.transform = `translateY(${(10 * (1 - easeOut(k))).toFixed(2)}px)`;
    }
    const isApp = s => !!s.said;
    // The foot fades with the scene, applied to each part rather than the group, so no compositing
    // layer comes and goes with history.
    footAlpha = prev != null ? mix(isApp(SCENES[prev]) ? 1 : 0, isApp(sc) ? 1 : 0, k) : isApp(sc) ? 1 : 0;
    if (shownScene !== sc.id) { appName.textContent = sc.app; stage.dataset.scene = sc.id; shownScene = sc.id; slipFor = null; }
    let phase = 'done';
    if (sc.said) phase = drawScene(sc, u, sched);
    else if (sc.id === 'savings') phase = drawSavings(u);
    if (!sc.said) { slip.style.opacity = '0'; drawFoot(.36, 0, 1); }
    stage.dataset.phase = phase;
    return phase;
  }

  // ---- Live mode: keys drive a clock; drawing stops when nothing moves -------------------------------
  const live = { i: 0, prev: null, enteredAt: 0, playAt: null, release: null, raf: 0 };
  const now = () => performance.now() / 1000;
  function tick() {
    const t = now(), sc = SCENES[live.i];
    const local = t - live.enteredAt, u = live.playAt == null ? null : t - live.playAt;
    const sched = sc.said && u != null ? schedule(sc, live.release) : null;
    const phase = frame(live.i, local, u, sched, live.prev);
    const settling = local < T.swap || (u != null && phase !== 'done');
    live.raf = settling ? requestAnimationFrame(tick) : 0;
  }
  function kick() { cancelAnimationFrame(live.raf); live.raf = requestAnimationFrame(tick); }
  function enter(i, withFade = true) {
    const next = Math.max(0, Math.min(SCENES.length - 1, i));
    live.prev = withFade && next !== live.i ? live.i : null;
    live.i = next; live.enteredAt = now(); live.playAt = null; live.release = null;
    for (const id of Object.keys(templates)) resetWindow(id);
    tick();
  }
  const phaseNow = () => stage.dataset.phase;
  function play(release = null) { const sc = SCENES[live.i]; if (!(sc.said || sc.id === 'savings') || live.playAt != null) return; live.playAt = now(); live.release = release; tick(); }
  // Finish the scene at once: its end state, no animation.
  function snap() { const sc = SCENES[live.i]; live.playAt = now() - (sc.said ? schedule(sc).doneAt : T.count) - 1; live.release = null; live.enteredAt = now() - T.swap; tick(); }
  function advance() {
    const ph = phaseNow();
    if (ph === 'ready') return play();
    if (ph !== 'done') return snap();
    if (live.i < SCENES.length - 1) enter(live.i + 1);
  }
  const back = () => enter(live.i - 1);
  function replay() { enter(live.i, false); play(); }

  // ---- Seek API: deterministic frames for rendering ------------------------------------------------
  // The default timeline plays the scenes in order with the holds from scenes.json: title for its
  // `hold`; each other scene `readyHold`, then its play, then `doneHold`. seek() beyond the end shows
  // the last frame.
  function timeline() {
    // Chapter starts come from scenes.json `timeline.starts` (the video's chapters); each scene plays
    // `readyHold` seconds after it starts and holds its end state until the next one starts.
    const starts = DATA.timeline.starts, end = DATA.timeline.duration;
    return SCENES.map((sc, i) => {
      const start = starts[sc.id], next = i + 1 < SCENES.length ? starts[SCENES[i + 1].id] : end;
      const playAt = sc.readyHold == null ? null : start + sc.readyHold;
      return { id: sc.id, index: i, start, playAt, playLength: playLength(sc), end: next };
    });
  }
  function pause() { cancelAnimationFrame(live.raf); live.raf = 0; }
  // A scene at `local` seconds since it was entered, playing after `playAfter` seconds (default its
  // readyHold). No crossfade unless `fromId` names the scene it fades in from.
  function seekScene(id, local, opts = {}) {
    pause();
    const i = SCENES.findIndex(s => s.id === id); if (i < 0) throw new Error('unknown scene ' + id);
    const sc = SCENES[i], playAfter = opts.playAfter ?? sc.readyHold ?? Infinity;
    const prev = opts.fromId ? SCENES.findIndex(s => s.id === opts.fromId) : null;
    const u = local >= playAfter ? local - playAfter : null;
    live.i = i; live.prev = prev; live.enteredAt = now() - local; live.playAt = u == null ? null : now() - u; live.release = null;
    return frame(i, local, u, sc.said && u != null ? schedule(sc) : null, prev);
  }
  function seek(seconds) {
    const segs = timeline(), t = Math.max(0, seconds);
    const seg = segs.find(s => t < s.end) || segs[segs.length - 1];
    const local = Math.min(t, seg.end) - seg.start;
    return seekScene(seg.id, local, { playAfter: seg.playAt == null ? Infinity : seg.playAt - seg.start, fromId: seg.index ? SCENES[seg.index - 1].id : undefined });
  }

  // ---- Keys ------------------------------------------------------------------------------------------
  let helpTimer = 0;
  function toggleHelp(show = help.hidden) { help.hidden = !show; clearTimeout(helpTimer); if (show) helpTimer = setTimeout(() => { help.hidden = true; }, 6000); }
  let holding = false;
  addEventListener('keydown', e => {
    if (e.metaKey || e.altKey) return;   // leave browser and system shortcuts alone
    if (e.code === 'ControlRight') {
      e.preventDefault();
      if (!e.repeat && phaseNow() === 'ready' && SCENES[live.i].said) { holding = true; play(Infinity); }
      return;
    }
    if (e.ctrlKey) return;
    switch (e.code) {
      case 'Space': case 'ArrowRight': case 'PageDown': e.preventDefault(); if (!e.repeat) advance(); break;
      case 'Backspace': case 'ArrowLeft': case 'PageUp': e.preventDefault(); if (!e.repeat) back(); break;
      case 'KeyR': if (!e.repeat) replay(); break;
      case 'Home': e.preventDefault(); enter(0, false); break;
      case 'KeyF': if (!e.repeat) { document.fullscreenElement ? document.exitFullscreen() : document.documentElement.requestFullscreen?.(); } break;
      case 'Escape': toggleHelp(false); break;
      default: if (e.key === '?') toggleHelp();
    }
  });
  addEventListener('keyup', e => {
    if (e.code !== 'ControlRight' || !holding) return;
    holding = false;
    if (live.playAt != null && live.release === Infinity) { live.release = now() - live.playAt; kick(); }
  });
  let pointerTimer = 0;
  addEventListener('pointermove', () => { document.body.classList.add('show-cursor'); clearTimeout(pointerTimer); pointerTimer = setTimeout(() => document.body.classList.remove('show-cursor'), 1500); });

  // ---- Ready signal and API ----------------------------------------------------------------------
  const ready = Promise.all([
    document.fonts.ready,
    // Decode every image now, including ones not yet shown (the sun, app icons), so the first frame
    // that shows one never paints it undecoded.
    ...[...document.images].map(img => img.decode().catch(() => {})),
    new Promise(resolve => { const bg = new Image(); bg.onload = bg.onerror = resolve; bg.src = getComputedStyle(stage.querySelector('.wallpaper')).backgroundImage.match(/url\("?([^")]+)/)?.[1] || ''; }),
  ]).then(() => { document.documentElement.dataset.stageReady = '1'; return true; });

  window.stage = {
    ready,
    state: () => ({ scene: SCENES[live.i].id, index: live.i, phase: phaseNow() }),
    seek, seekFrame: (n, fps = 60) => seek(n / fps), seekScene, pause, timeline,
    duration: () => timeline().at(-1).end,
    playLength: id => playLength(SCENES.find(s => s.id === id)),
    schedule: id => schedule(SCENES.find(s => s.id === id)),
    go: id => enter(SCENES.findIndex(s => s.id === id), false), advance, back, replay, snap, reset: () => enter(0, false),
    savedSeconds, scenes: SCENES.map(s => s.id), data: DATA,
  };
  enter(0, false);
})();
