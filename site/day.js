// The home page below the hero: the drawn rules, and the day's sky.
(() => {
  const root = document.documentElement;
  const still = matchMedia('(prefers-reduced-motion: reduce)');

  // The rule under a heading or a call to action, drawn by hand: one pen width with a waver under
  // a point, seeded so it is the same hand on every visit (as the design foundation's hand.js
  // draws it). pathLength lets CSS draw it on.
  function drawRules() {
    document.querySelectorAll('.hand-rule').forEach((svg, i) => {
      const w = Math.max(20, svg.getBoundingClientRect().width);
      let seed = (7 + i * 31) >>> 0;
      const rnd = () => (seed = (seed * 1664525 + 1013904223) >>> 0) / 4294967296;
      const points = [];
      for (let x = 0; x <= w; x += 12) points.push([Math.min(x, w), 3 + (rnd() - 0.5) * 1.4 + Math.sin(x / 40) * 0.35]);
      if (points.at(-1)[0] < w) points.push([w, 3 + (rnd() - 0.5) * 1.4]);
      let d = `M ${points[0][0].toFixed(1)} ${points[0][1].toFixed(2)}`;
      for (let j = 1; j < points.length; j++) {
        const [x0, y0] = points[j - 1];
        const [x1, y1] = points[j];
        d += ` Q ${((x0 + x1) / 2).toFixed(1)} ${y0.toFixed(2)} ${x1.toFixed(1)} ${y1.toFixed(2)}`;
      }
      svg.setAttribute('viewBox', `0 0 ${w.toFixed(1)} 6`);
      svg.innerHTML = `<path pathLength="1" d="${d}"/>`;
    });
  }
  drawRules();
  document.fonts?.ready.then(drawRules);

  // Each band's heading rule draws once, when the band arrives.
  const blocks = document.querySelectorAll('.drawn-block');
  if ('IntersectionObserver' in window && !still.matches) {
    const arrive = new IntersectionObserver(entries => {
      for (const entry of entries) if (entry.isIntersecting) { entry.target.classList.add('is-drawn'); arrive.unobserve(entry.target); }
    }, { threshold: 0.35 });
    blocks.forEach(block => arrive.observe(block));
  } else {
    blocks.forEach(block => block.classList.add('is-drawn'));
  }

  // The day. One sky stays behind every stop under the hero: as each stop's centre passes the middle
  // of the screen its painting is fully up, and between two stops the next painting fades in over
  // the middle of the way. The sun follows an arc from the left (--s 0) to the right (--s 1) and
  // goes down past it; the moon comes up for the night. Neither leaves its arc: where words or a
  // window come near, it fades out, so it shows only in open sky and never beside a heading or under
  // a window as a stray dot. While a stop marked data-sky="none" is on the screen (the Notes window,
  // whose foot mark is the listening sun) it hides. Geometry is measured only on resize, so a scroll frame reads scrollY and
  // writes opacity and transform, nothing else, and only what changed.
  const day = document.querySelector('.day');
  const sky = day?.querySelector('.day-sky');
  if (!sky) return;
  const layers = [...sky.querySelectorAll('.day-painting')];
  const names = layers.map(layer => layer.dataset.painting);
  const sun = sky.querySelector('.day-sun');
  const moon = sky.querySelector('.day-moon');
  const stops = [...day.querySelectorAll('.stop')].map(el => ({
    el,
    painting: Math.max(0, names.indexOf(el.dataset.painting)),
    s: parseFloat(el.style.getPropertyValue('--s')) || 0,
    moon: el.dataset.light === 'night' ? 1 : 0,
    hide: el.dataset.sky === 'none',
    top: 0,
    bottom: 0,
    center: 0
  }));
  // What the sun and the moon keep clear of. Text is measured by its own ink box, not its block's
  // full width, so a centred heading does not claim the sky beside it.
  const KEEP_CLEAR = '.hero-demo .said, .hero-demo .app-window, .day .sheet-title, .day .heading-rule, .beat-line, .beat-label, .day .said, .cue, .who, .day .app-window, .step-line, .step-note, .company-title, .company-line, .community-logos, .join-sheet';
  const BLOCKS = '.app-window, .who, .community-logos, .join-sheet, .heading-rule';
  let rects = [];
  // How far the disc's centre is from the nearest words or window, in the page's coordinates. A gap
  // to the side counts half, because a disc level with a line reads as its bullet from far off.
  function gap(x, y) {
    let d = Infinity;
    for (const [l, t, r, b] of rects) {
      const dx = Math.max(l - x, 0, x - r), dy = Math.max(t - y, 0, y - b);
      d = Math.min(d, Math.hypot(dx / 2, dy));
    }
    return d;
  }
  // Full in open sky; gone within NEAR of the words, across a FADE of distance. On a wide screen the
  // sun stands well off the words; on a phone,
  // where it keeps to the top edge, words pass under it and it steps aside for them.
  let NEAR = 0, FADE = 0;
  const open = d => smooth(Math.min(1, Math.max(0, (d - NEAR) / FADE)));
  const written = new Map();
  const write = (el, property, value) => {
    const key = written.get(el) || {};
    if (key[property] === value) return;
    key[property] = value;
    written.set(el, key);
    el.style[property] = value;
  };
  const smooth = t => t * t * (3 - 2 * t);
  // The paintings change over the middle 40 percent of the way between two stops.
  const fade = t => smooth(Math.min(1, Math.max(0, (t - 0.3) / 0.4)));

  let live = false, vw = 0, vh = 0, phone = false, top = 0, bottom = 0, lastY = NaN, queued = 0;

  function measure() {
    live = root.classList.contains('day-live');
    if (!live) return;
    vw = sky.clientWidth;
    vh = sky.clientHeight;
    phone = vw <= 600;
    const box = day.getBoundingClientRect();
    top = box.top + scrollY;
    bottom = box.bottom + scrollY;
    NEAR = phone ? 26 : Math.max(60, 0.1 * vw);
    FADE = phone ? 18 : 60;
    for (const stop of stops) {
      const r = stop.el.getBoundingClientRect();
      stop.top = r.top + scrollY;
      stop.bottom = r.bottom + scrollY;
      stop.center = stop.top + r.height / 2;
    }
    const range = document.createRange();
    rects = [...document.querySelectorAll(KEEP_CLEAR)].map(el => {
      let b = el.getBoundingClientRect();
      if (!el.matches(BLOCKS)) { range.selectNodeContents(el); b = range.getBoundingClientRect(); }
      return [b.left, b.top + scrollY, b.right, b.bottom + scrollY];
    }).filter(([l, t, r, b]) => r > l && b > t);
    lastY = NaN;
    schedule();
  }

  function frame() {
    queued = 0;
    const y = scrollY;
    if (!live || y === lastY) return;
    lastY = y;
    // Off screen the sky keeps its last state.
    if (y + vh < top || y > bottom) return;
    const c = y + vh / 2;
    let i = 0;
    while (i < stops.length - 1 && stops[i + 1].center <= c) i++;
    const a = stops[i];
    const b = stops[Math.min(i + 1, stops.length - 1)];
    const t = a === b || c <= a.center ? 0 : Math.min(1, (c - a.center) / (b.center - a.center));
    const f = fade(t);
    const p = a.painting + (b.painting - a.painting) * f;
    const s = a.s + (b.s - a.s) * t;
    const m = a.moon + (b.moon - a.moon) * f;

    const base = Math.floor(p);
    const over = p - base;
    layers.forEach((layer, k) => {
      const opacity = k === base ? 1 : k === base + 1 ? over : 0;
      write(layer, 'opacity', opacity.toFixed(3));
      write(layer, 'visibility', opacity > 0 ? 'visible' : 'hidden');
    });

    // Past the last stop of the day the sun goes on down its arc.
    const [sx, sy] = sunAt(Math.min(s, 1.12));
    // Where the sky's top edge is on the page: the screen's top while the sky sticks, and below it
    // while the day is still rising under the hero's foot, where the hero's spoken line and window are.
    const skyTop = Math.min(Math.max(y, top), bottom - vh);
    // A stop that keeps the sky clear does so for as long as any of it is on the screen.
    let hidden = 0;
    for (const stop of stops) if (stop.hide) hidden = Math.max(hidden, smooth(Math.min(1, Math.max(0, Math.min(stop.bottom - y, y + vh - stop.top) / 120))));
    write(sun, 'transform', `translate3d(${sx.toFixed(1)}px, ${sy.toFixed(1)}px, 0)`);
    // While the sky is still rising out of the hero's foot, the sun and the moon come up with it.
    const up = Math.max(0, Math.min(1, 1 - (top - y) / (0.25 * vh)));
    // The sun dims a little as it sets, then goes down at the horizon.
    const dim = 1 - 0.18 * smooth(Math.min(1, Math.max(0, (s - 0.7) / 0.25)));
    const sunUp = Math.max(0, Math.min(1, 1 - (s - 0.97) / 0.06));
    write(sun, 'opacity', (sunUp ? up * dim * sunUp * (1 - hidden) * open(gap(sx, sy + skyTop)) : 0).toFixed(3));
    // The moon comes up in the east, at the left, as the sun sets at the right.
    const [mx, my] = moonAt(m);
    write(moon, 'transform', `translate3d(${mx.toFixed(1)}px, ${my.toFixed(1)}px, 0)`);
    write(moon, 'opacity', (m ? up * m * (1 - hidden) * open(gap(mx, my + skyTop)) : 0).toFixed(3));
  }

  // Where the sun stands at s along its arc. On a wider screen it rises low over the hills at the
  // left, fully inside the frame, and sets into the lake just left of the inscribed stone (at s 1),
  // so it never crosses the stone. On a phone, where the
  // windows fill the screen, it keeps to the band of sky at the top edge, crossing from left to right.
  function sunAt(s) {
    if (phone) return [vw * (0.1 + 0.8 * s), 26 + 12 * (1 - Math.sin(Math.PI * Math.min(s, 1)))];
    return [vw * (0.055 + 0.73 * s), vh * (0.6 - 0.48 * Math.sin(Math.PI * s))];
  }

  // Where the moon stands when it is m of the way up; on a phone it keeps to the sky at the right.
  function moonAt(m) {
    return phone ? [0.8 * vw, 28 + (1 - m) * 0.04 * vh] : [0.2 * vw, (0.16 + (1 - m) * 0.08) * vh];
  }

  function schedule() { if (!queued) queued = requestAnimationFrame(frame); }

  addEventListener('scroll', schedule, { passive: true });
  addEventListener('resize', measure, { passive: true });
  addEventListener('load', measure);
  // The stops change height as fonts and windows arrive.
  if ('ResizeObserver' in window) new ResizeObserver(measure).observe(day);
  // Turning reduced motion on shows the stills; turning it off brings the sky back.
  still.addEventListener('change', () => { root.classList.toggle('day-live', !still.matches); measure(); });
  measure();
})();
