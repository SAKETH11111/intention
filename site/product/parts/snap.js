// The small dots sit on the device pixel grid. Below 20 px a dot is a true circle with an even
// 1.5 px hairline (the shared spec's "Small sizes are true circles"), and its edge and ring only
// stay even when they fall on whole device pixels; layout puts them on fractions. So each dot is
// moved by under a pixel with the translate property, after layout changes, scrolls and state
// changes. Contract: the foot mark (.sun-mark) and the caret dot's core (.ui-dot .dot-core).
(() => {
  const dots = [...document.querySelectorAll('.sun-mark, .ui-dot .dot-core')];
  if (!dots.length) return;
  const shift = new WeakMap();
  let frame = 0;
  const snap = () => {
    frame = 0;
    const scale = devicePixelRatio || 1;
    // Read every position first, then write, so the layout is computed once.
    const moves = dots.map(dot => {
      const rect = dot.getBoundingClientRect();
      if (!rect.width) return null;
      const [sx, sy] = shift.get(dot) || [0, 0];
      const x = rect.left - sx, y = rect.top - sy;
      return [dot, Math.round(x * scale) / scale - x, Math.round(y * scale) / scale - y];
    });
    for (const move of moves) {
      if (!move) continue;
      const [dot, dx, dy] = move;
      shift.set(dot, [dx, dy]);
      dot.style.translate = `${dx.toFixed(3)}px ${dy.toFixed(3)}px`;
    }
  };
  const soon = () => { if (!frame) frame = requestAnimationFrame(snap); };
  addEventListener('resize', soon);
  addEventListener('scroll', soon, { passive: true });
  document.fonts?.ready.then(soon);
  const stages = new Set(dots.map(dot => dot.closest('.stage') || document.body));
  const resized = new ResizeObserver(soon);
  const changed = new MutationObserver(soon);
  for (const stage of stages) {
    resized.observe(stage);
    // A new state, a window shown or hidden, or text landing before the caret can each move a dot.
    changed.observe(stage, { subtree: true, childList: true, characterData: true, attributes: true, attributeFilter: ['data-state', 'hidden'] });
  }
  soon();
})();
