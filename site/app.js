// A finite intro on every fresh arrival, independent of network completion.
// Escape and reduced motion use the same cleanup so the page never remains
// clipped or inert.
function startIntro() {
  const screen = document.querySelector('.intro-screen');
  const hero = document.querySelector('.hero');
  // The reveal clips the whole page, so the peek of the next section arrives through the circle too.
  const page = document.querySelector('.page') || hero;
  const letter = document.querySelector('.intro-letter');
  const dot = document.querySelector('.intro-dot');
  const stem = document.querySelector('.intro-stem');
  const circle = document.querySelector('.intro-circle');
  const preference = matchMedia('(prefers-reduced-motion: reduce)');
  const animations = new Set();
  // The call to action's rule and arrow draw as it lands, so the hand-lettered
  // label is never seen bare (bare, it reads as a heading).
  const drawMarks = () => hero.querySelectorAll('.cta, .draw-arrow').forEach(el => el.classList.add('is-drawn'));
  let finished = false;
  let watchdog;

  function finish({ returnFocus = false } = {}) {
    if (finished) return;
    finished = true;
    clearTimeout(watchdog);
    for (const animation of animations) animation.cancel();
    animations.clear();
    screen.remove();
    page.inert = false;
    page.style.clipPath = '';
    page.classList.remove('intro-reveal');
    document.body.classList.remove('intro-running');
    window.removeEventListener('keydown', onKey);
    window.removeEventListener('resize', onResize);
    preference.removeEventListener('change', onPreference);
    if (returnFocus) hero.querySelector('.hero-join').focus({ preventScroll: true });
    drawMarks();
    // The hero's demo (demo.js) waits for this before its first play.
    document.dispatchEvent(new Event('intro:done'));
  }

  function onKey(event) {
    if (event.key === 'Escape') finish({ returnFocus: true });
    // The hero is inert while the intro runs, so Tab has nowhere to go yet.
    if (event.key === 'Tab' && !finished) event.preventDefault();
  }
  function onResize() { finish(); }
  function onPreference(event) { if (event.matches) finish(); }

  function animate(element, keyframes, options) {
    const animation = element.animate(keyframes, { fill: 'both', ...options });
    animations.add(animation);
    return animation.finished.catch(() => {});
  }

  if (document.documentElement.classList.contains('skip-intro') || preference.matches || !Element.prototype.animate) {
    finish();
    return;
  }

  document.body.classList.add('intro-running');
  page.inert = true;
  window.addEventListener('keydown', onKey);
  window.addEventListener('resize', onResize);
  preference.addEventListener('change', onPreference);
  watchdog = setTimeout(finish, 4200);

  async function run() {
    // Keep the actual text and spacing accessible while animating each word.
    const headline = hero.querySelector('.one-liner');
    const words = headline.textContent.trim().split(/\s+/);
    headline.replaceChildren(...words.flatMap((word, index) => {
      const span = document.createElement('span');
      span.className = 'reveal-word';
      span.textContent = word;
      return index ? [document.createTextNode(' '), span] : [span];
    }));
    const arrivals = [];
    const arrive = (element, delay, distance, duration = 700) => {
      arrivals.push(animate(element, [
        { opacity: 0, transform: `translateY(${distance}px)` },
        { opacity: 1, transform: 'translateY(0)' }
      ], { delay, duration, easing: 'cubic-bezier(.16,1,.3,1)' }));
    };
    arrive(hero.querySelector('.wordmark'), 1300, 38, 700);
    headline.querySelectorAll('.reveal-word').forEach((word, index) => {
      arrive(word, 1460 + index * 40, 15, 520);
    });
    arrive(hero.querySelector('.sub-line'), 1560, 14, 540);
    arrive(hero.querySelector('.hero-actions'), 1600, 18, 600);
    arrive(hero.querySelector('.scroll-link'), 1680, 12, 600);
    setTimeout(drawMarks, 1600);

    animate(letter, [
      { opacity: 0, transform: 'translate(-50%, calc(-50% + 10px)) scale(.94)' },
      { opacity: 1, transform: 'translate(-50%, -50%) scale(1)' }
    ], { delay: 0, duration: 220, easing: 'cubic-bezier(.2,.7,.2,1)' });

    // The fall meets a resisting stem, then drives it down into a brief hold.
    // Contact stays continuous; there is no rebound after the landing.
    const impactEnd = 1210;
    const contact = [
      { time: 640, stemX: 1, stemY: 1, dotX: 1, dotY: 1, ease: 'cubic-bezier(.3,0,.7,1)' },
      { time: 700, stemX: 1.04, stemY: .93, dotX: 1.08, dotY: .91, ease: 'cubic-bezier(.35,0,.25,1)' },
      { time: 900, stemX: 1.28, stemY: .12, dotX: 1.24, dotY: .76, ease: 'linear' },
      { time: 1000, stemX: 1.28, stemY: .12, dotX: 1.24, dotY: .76, ease: 'cubic-bezier(.4,0,.2,1)' }
    ];
    const dotFrames = [
      { transform: 'translate(0,0) scale(1)', offset: 0 },
      { transform: 'translate(0,0) scale(1)', offset: 120 / impactEnd, easing: 'cubic-bezier(.16,.7,.3,1)' },
      { transform: 'translate(0,-120px) scale(1)', offset: 420 / impactEnd },
      { transform: 'translate(0,-120px) scale(1)', offset: 470 / impactEnd, easing: 'cubic-bezier(.55,0,.9,.45)' },
      ...contact.map(frame => ({
        transform: `translate(0,${245 - 153 * frame.stemY - 34 - 32 * frame.dotY}px) scale(${frame.dotX},${frame.dotY})`,
        offset: frame.time / impactEnd,
        easing: frame.ease
      })),
      { transform: 'translate(-6px,167px) scale(1.3)', offset: 1 }
    ];
    animate(dot, dotFrames, { duration: impactEnd, easing: 'linear' });

    // Deform the approved path only during the intro. The shaft spreads under
    // pressure while the broad foot keeps its width until the final gathering.
    const sourcePath = stem.getAttribute('d');
    function compressedPath(width, height, footWidth = 1) {
      let index = 0;
      const points = [...sourcePath.matchAll(/-?\d+(?:\.\d+)?/g)].map(match => Number(match[0]));
      return sourcePath.replace(/-?\d+(?:\.\d+)?/g, () => {
        const position = index++;
        const value = points[position];
        if (position % 2) return (245 - (245 - value) * height).toFixed(3);
        const y = points[position + 1];
        const shaft = Math.min(1, Math.max(0, (208 - y) / 70));
        return (57 + (value - 57) * (footWidth + (width - footWidth) * shaft)).toFixed(3);
      });
    }
    const morphsPaths = CSS.supports('d', 'path("M0 0 L1 1")');
    const shape = (width, height, footWidth = 1) => morphsPaths
      ? { d: `path("${compressedPath(width, height, footWidth)}")` }
      : { transform: `scale(${width},${height})` };
    animate(stem, [
      ...contact.map(frame => ({
        ...shape(frame.stemX, frame.stemY),
        offset: (frame.time - 640) / (impactEnd - 640),
        easing: frame.ease
      })),
      { ...shape(.65, .12, .65), offset: 1 }
    ], { delay: 640, duration: impactEnd - 640, easing: 'linear' });

    // Register the circle to the actual SVG baseline, not an estimated screen
    // offset. The dark circle covers the gathered pieces before they disappear.
    const glyphScale = 76 / 124;
    const baseline = { x: innerWidth / 2, y: innerHeight * .42 + (245 - 123) * glyphScale };
    circle.style.left = `${baseline.x}px`;
    circle.style.top = `${baseline.y - 27}px`;
    await animate(circle, [
      { opacity: 0, transform: 'translate(-50%,-50%) scale(1)' },
      { opacity: 1, transform: 'translate(-50%,-50%) scale(1)' }
    ], { delay: 1120, duration: 110, easing: 'ease-out' });
    if (finished) return;
    letter.style.visibility = 'hidden';
    // The landscape is revealed through the circle's exact center. A radius
    // reaching the furthest corner avoids clipping on tall and wide screens.
    const circleBounds = circle.getBoundingClientRect();
    const x = circleBounds.left + circleBounds.width / 2;
    const y = circleBounds.top + circleBounds.height / 2;
    const radius = Math.hypot(Math.max(x, innerWidth - x), Math.max(y, innerHeight - y)) + 2;
    page.style.clipPath = `circle(27px at ${x}px ${y}px)`;
    page.classList.add('intro-reveal');
    screen.style.background = 'transparent';
    animate(circle, [{ opacity: 1 }, { opacity: 0 }], { duration: 220, easing: 'ease-out' });
    await animate(page, [
      { clipPath: `circle(27px at ${x}px ${y}px)` },
      { clipPath: `circle(${radius}px at ${x}px ${y}px)` }
    ], { duration: 820, easing: 'cubic-bezier(.76,0,.24,1)' });
    await Promise.all(arrivals);
    finish();
  }

  run().catch(() => finish());
}

startIntro();

// The drawn marks on the calls to action: the waitlist's draw as it scrolls
// in, and hovering any of them draws it again, once. The marks are drawn in
// the markup; only once this has run do the ones not yet drawn hide, so a
// script that fails never leaves a label bare.
(() => {
  const marks = document.querySelectorAll('.cta, .draw-arrow');
  const later = [...document.querySelectorAll('.cta')].filter(el => !el.closest('.hero'));
  document.documentElement.classList.add('marks-draw');
  if ('IntersectionObserver' in window) {
    const arrive = new IntersectionObserver(entries => {
      for (const entry of entries) if (entry.isIntersecting) { entry.target.classList.add('is-drawn'); arrive.unobserve(entry.target); }
    }, { threshold: 0.25 });
    later.forEach(el => arrive.observe(el));
  } else later.forEach(el => el.classList.add('is-drawn'));
  const still = matchMedia('(prefers-reduced-motion: reduce)');
  for (const el of marks) {
    el.addEventListener('pointerenter', () => {
      if (still.matches || !el.classList.contains('is-drawn')) return;
      el.classList.add('no-ease');
      el.classList.remove('is-drawn');
      void el.getBoundingClientRect();
      el.classList.remove('no-ease');
      el.classList.add('is-drawn');
    });
  }
})();

// A painting that fails to load would show the browser's broken-image mark over the hero (WebKit
// draws one even with empty alt); it stays hidden until it loads, so the sky shows instead.
for (const art of document.querySelectorAll('.hero .landscape')) {
  const broken = () => art.classList.toggle('is-broken', art.complete && art.naturalWidth === 0);
  art.addEventListener('error', broken);
  art.addEventListener('load', broken);
  broken();
}

// The hero's links glide down the page (Join the waitlist to the form, the arrow to the moment under
// the fold) and jump there under reduced motion. Focus follows, so the keyboard carries on from
// there. Without JavaScript each is a plain jump.
for (const link of document.querySelectorAll('.hero a[href^="#"]')) {
  link.addEventListener('click', event => {
    const target = document.querySelector(link.hash);
    if (!target) return;
    event.preventDefault();
    const still = matchMedia('(prefers-reduced-motion: reduce)').matches;
    target.scrollIntoView({ behavior: still ? 'auto' : 'smooth', block: 'start' });
    target.focus({ preventScroll: true });
  });
}
