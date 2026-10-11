(() => {
  'use strict';
  // The waitlist as the page draws it, kept on this device. This static site has no server: a
  // submission sends nothing and stores nothing, and the thank-you says so.
  const hosts = [...document.querySelectorAll('[data-waitlist]')];
  if (!hosts.length) return;
  const css = document.createElement('link'); css.rel = 'stylesheet'; css.href = '/waitlist.css'; document.head.append(css);

  // The submit is an ink call to action like the page's own, so it draws itself the same way:
  // on arrival, again on hover, and at once under reduced motion.
  function drawInk(el) {
    const rule = el.querySelector('.cta-rule'), path = rule.querySelector('path'), shape = path.getAttribute('d');
    const fit = () => {
      const w = rule.getBoundingClientRect().width;
      rule.setAttribute('viewBox', `0 0 ${w.toFixed(1)} 6`);
      path.setAttribute('d', shape.replace(/([\d.]+) ([\d.]+)/g, (_, x, y) => `${(x * w / 100).toFixed(1)} ${y}`));
    };
    fit(); document.fonts?.ready.then(fit);
    const still = matchMedia('(prefers-reduced-motion: reduce)');
    if (still.matches || !('IntersectionObserver' in window)) el.classList.add('is-drawn');
    else {
      const arrive = new IntersectionObserver(entries => { if (entries.some(entry => entry.isIntersecting)) { el.classList.add('is-drawn'); arrive.disconnect(); } }, {threshold:0.25});
      arrive.observe(el);
    }
    el.addEventListener('pointerenter', () => {
      if (still.matches || !el.classList.contains('is-drawn')) return;
      el.classList.add('no-ease'); el.classList.remove('is-drawn');
      void el.getBoundingClientRect();
      el.classList.remove('no-ease'); el.classList.add('is-drawn');
    });
  }
  function inkAction(label) {
    return `<button class="cta" type="submit"><span class="cta-label">${label}<svg class="cta-rule hand-rule" viewBox="0 0 100 6" preserveAspectRatio="none" aria-hidden="true"><path pathLength="1" d="M 0 3.3 Q 12 2.5 25 3.1 Q 38 3.7 50 3 Q 63 2.4 75 3.2 Q 88 3.8 100 2.9"/></svg></span><svg class="cta-go" viewBox="0 0 22 14" aria-hidden="true"><path pathLength="1" d="M1.2 7.4 C 6.4 6.8 11.6 7.3 19.6 7"/><path pathLength="1" d="M14.6 2.3 C 16.5 4 18.2 5.5 19.8 7 C 18 8.7 16.3 10.2 14.5 11.9"/></svg></button>`;
  }
  function thank(host) {
    host.replaceChildren();
    host.dataset.joined = 'free';
    const heading = document.createElement('h3');
    heading.innerHTML = '<svg class="hand-check" viewBox="0 0 14 12" aria-hidden="true"><path pathLength="1" d="M1.5 6.8 C 3 7.6 4.3 9.2 5.1 10.6 M5.1 10.6 C 6.9 6.6 9.6 3.6 12.8 1.4"/></svg>';
    heading.append('Thank you.');
    const note = document.createElement('p');
    note.textContent = "This site doesn't keep sign-ups yet, so your email wasn't sent or saved.";
    host.append(heading, note);
    heading.tabIndex = -1; heading.focus({preventScroll:true});
  }
  hosts.forEach(host => {
    host.classList.add('waitlist'); host.hidden = false;
    host.innerHTML = `<form>
      <label class="waitlist-email"><span class="sr-only">Email</span><input name="email" type="email" autocomplete="email" maxlength="254" required placeholder="Email"></label>
      ${inkAction('Join the waitlist')}<p role="status"></p>
    </form><p>This form doesn't send or store your email. <a href="/privacy/">Privacy</a></p>`;
    drawInk(host.querySelector('.cta'));
    host.querySelector('form').onsubmit = event => {
      event.preventDefault();
      const form = event.currentTarget;
      if (!form.reportValidity()) return;
      hosts.forEach(thank);
    };
  });
})();
