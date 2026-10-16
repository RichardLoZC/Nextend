// Use native buttons and aria-pressed for a group of mutually exclusive settings.
function mountGlassToolbar(group) {
  if (group.dataset.glassReady) return () => {};
  const buttons = [...group.querySelectorAll(':scope > button')];
  if (!buttons.length) return () => {};
  const selector = document.createElement('span');
  selector.className = 'lg-selector'; selector.setAttribute('aria-hidden', 'true');
  group.prepend(selector);
  const place = () => {
    const current = buttons.find(b => b.getAttribute('aria-pressed') === 'true');
    selector.hidden = !current;
    if (!current) return;
    selector.style.transform = `translate(${current.offsetLeft}px, ${current.offsetTop}px)`;
    selector.style.width = `${current.offsetWidth}px`;
    selector.style.height = `${current.offsetHeight}px`;
  };
  const choose = event => {
    const button = event.target.closest('button');
    if (!buttons.includes(button) || button.disabled) return;
    buttons.forEach(b => b.setAttribute('aria-pressed', String(b === button)));
    place(); group.dispatchEvent(new CustomEvent('glasschange', {detail: {value: button.dataset.value}, bubbles: true}));
  };
  group.dataset.glassReady = 'true';
  group.addEventListener('click', choose);
  const observer = new ResizeObserver(place); observer.observe(group); buttons.forEach(b => observer.observe(b));
  place();
  return () => { observer.disconnect(); group.removeEventListener('click', choose); selector.remove(); delete group.dataset.glassReady; };
}
