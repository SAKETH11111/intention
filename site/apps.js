// The sentence ends with the logo of an app Intention writes in. One logo fades
// into the next every 2.2 seconds inside a fixed box, so the line never moves.
// It keeps going round all of them (every app should show). It
// pauses while the pointer is on the sentence or keyboard focus is in the hero,
// and while the sentence is off screen or the tab is hidden. The pointer pause is
// the sentence's, not the hero's: the hero fills the first screen, so a resting
// mouse would otherwise stop it for nearly every desktop visitor. Reduced motion
// shows Gmail and never moves.
(() => {
  const cycle = document.querySelector('.apps-cycle');
  if (!cycle) return;
  const base = new URL('assets/apps/', document.currentScript?.src || location.href);
  const apps = [['gmail', 'Gmail'], ['substack', 'Substack'], ['notion', 'Notion'], ['slack', 'Slack'], ['linkedin', 'LinkedIn'], ['x', 'X'], ['imessage', 'iMessage'], ['whatsapp', 'WhatsApp'], ['instagram', 'Instagram'], ['outlook', 'Outlook'], ['medium', 'Medium']];
  const reduced = matchMedia('(prefers-reduced-motion: reduce)');
  const logos = apps.map(([slug, name]) => {
    const item = document.createElement('span');
    item.className = 'apps-logo';
    const img = document.createElement('img');
    img.src = new URL(`${slug}.svg`, base);
    img.alt = '';
    img.width = 24; img.height = 24;
    img.decoding = 'async';
    const label = document.createElement('span');
    label.textContent = name;
    label.append(Object.assign(document.createElement('span'), { className: 'apps-stop', textContent: '.' }));
    item.append(img, label);
    return item;
  });
  cycle.replaceChildren(...logos);
  let index = 0;
  // The box holds the widest name, so the sentence never reflows. Where the name has a line of its
  // own (phones, day.css), the box follows the name shown instead, so that line stays centred.
  const ownLine = () => getComputedStyle(cycle.closest('.apps-in') || cycle).display === 'block';
  const fit = () => {
    const widths = logos.map(logo => logo.offsetWidth);
    cycle.style.width = `${Math.ceil(ownLine() ? widths[index] : Math.max(...widths))}px`;
  };
  requestAnimationFrame(fit);
  document.fonts?.ready.then(fit);
  addEventListener('resize', fit, { passive: true });
  logos[0].classList.add('is-on');
  let timer = 0;
  const line = cycle.closest('.sub-line') || cycle;
  const host = line.closest('.hero') || line;
  let onScreen = true, held = false;
  const swap = () => {
    logos[index].classList.remove('is-on');
    index = (index + 1) % logos.length;
    logos[index].classList.add('is-on');
    fit();
  };
  const halt = () => { clearInterval(timer); timer = 0; };
  // Runs only when nothing holds it: on screen, tab visible, no pointer on the sentence or focus in the hero, motion allowed.
  const update = () => {
    const free = onScreen && !held && !document.hidden && !reduced.matches;
    if (free && !timer) timer = setInterval(swap, 2200);
    else if (!free) halt();
  };
  // Focus a script parked somewhere (a link's landing, tabindex -1) is not the reader's, so it does not hold.
  const focused = () => host.contains(document.activeElement) && !document.activeElement.matches('[tabindex="-1"]');
  const hold = () => { held = line.matches(':hover') || focused(); update(); };
  for (const type of ['pointerenter', 'pointerleave']) line.addEventListener(type, () => setTimeout(hold));
  for (const type of ['focusin', 'focusout']) host.addEventListener(type, () => setTimeout(hold));
  new IntersectionObserver(entries => { onScreen = entries[0].isIntersecting; update(); }, { threshold: 0.2 }).observe(line);
  document.addEventListener('visibilitychange', update);
  reduced.addEventListener('change', () => {
    // Turning reduced motion on mid-way returns to Gmail; turning it off goes round again.
    if (reduced.matches) { logos[index].classList.remove('is-on'); index = 0; logos[0].classList.add('is-on'); fit(); }
    update();
  });
  // A pointer already on the sentence, or focus already in the hero, holds it from the start.
  hold();
})();
