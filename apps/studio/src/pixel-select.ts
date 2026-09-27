/**
 * A browser-native select cannot guarantee its popup uses the loaded bitmap
 * face: that menu belongs to the operating system. Keep the native control as
 * the form value, but expose a DOM menu that is rendered by the console UI.
 */
interface PixelSelectControl {
  readonly refresh: () => void;
}

const controls = new WeakMap<HTMLSelectElement, PixelSelectControl>();

export function enhancePixelSelects(root: ParentNode): void {
  root.querySelectorAll<HTMLSelectElement>('select').forEach((select) => {
    if (controls.has(select)) return;

    const document = select.ownerDocument;
    const wrapper = document.createElement('span');
    wrapper.className = 'pixel-select';
    select.replaceWith(wrapper);
    wrapper.append(select);
    select.classList.add('pixel-select-native');
    select.tabIndex = -1;
    select.setAttribute('aria-hidden', 'true');

    const toggle = document.createElement('button');
    toggle.type = 'button';
    toggle.className = 'pixel-select-toggle';
    const label = select.getAttribute('aria-label');
    if (label !== null) toggle.title = label;

    const menu = document.createElement('div');
    menu.className = 'pixel-select-menu';
    menu.hidden = true;
    menu.setAttribute('role', 'listbox');
    wrapper.append(toggle, menu);

    const close = (): void => {
      menu.hidden = true;
      toggle.setAttribute('aria-expanded', 'false');
    };
    const refresh = (): void => {
      const selected = select.selectedOptions.item(0);
      toggle.textContent = selected?.textContent ?? '';
      toggle.disabled = select.disabled;
      menu.replaceChildren();
      for (const option of Array.from(select.options)) {
        const choice = document.createElement('button');
        choice.type = 'button';
        choice.className = 'pixel-select-option';
        choice.textContent = option.textContent;
        choice.disabled = option.disabled;
        choice.setAttribute('role', 'option');
        choice.setAttribute('aria-selected', String(option.selected));
        choice.addEventListener('click', () => {
          select.value = option.value;
          select.dispatchEvent(new Event('change', { bubbles: true }));
          close();
          toggle.focus();
        });
        menu.append(choice);
      }
    };
    controls.set(select, { refresh });
    toggle.setAttribute('aria-haspopup', 'listbox');
    toggle.setAttribute('aria-expanded', 'false');
    toggle.addEventListener('click', () => {
      const willOpen = menu.hidden;
      close();
      if (willOpen) {
        menu.hidden = false;
        toggle.setAttribute('aria-expanded', 'true');
      }
    });
    toggle.addEventListener('keydown', (event) => {
      if (event.key === 'Escape') close();
    });
    wrapper.addEventListener('focusout', () => {
      window.setTimeout(() => {
        if (!wrapper.contains(document.activeElement)) close();
      });
    });
    select.addEventListener('change', refresh);
    new MutationObserver(refresh).observe(select, {
      attributes: true,
      childList: true,
      subtree: true,
    });
    queueMicrotask(refresh);
  });
}

export function refreshPixelSelect(select: HTMLSelectElement): void {
  controls.get(select)?.refresh();
}
