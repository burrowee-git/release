// <copy-button> — universal copy-to-clipboard element for all Burrowee sites.
// CANONICAL SOURCE: burrowee-git/resources brand/copy-button/. Vendored copies
// must be re-synced from here — do not edit vendored copies in place.
//
// Usage:
//   <copy-button value="text to copy" btn-class="ghost">Copy</copy-button>
//   el.value = 'dynamic text';               // property overrides the attribute
//   <copy-button icon value="…"></copy-button>  // glyph ⧉ → ✓ instead of a label
// Events (bubble): 'copy-success'; 'copy-error' (cancelable — call
// preventDefault() from a host toast handler to suppress the console.warn).

export const COPIED_RESET_MS = 5000;

class CopyButton extends HTMLElement {
  connectedCallback() {
    if (this._wired) return;
    this._wired = true;
    this._icon = this.hasAttribute('icon');
    this._idle = this.getAttribute('label') ?? this.textContent.trim() ?? 'Copy';
    if (!this._idle && !this._icon) this._idle = 'Copy';

    const btn = document.createElement('button');
    btn.type = 'button';
    btn.className = ('copy-button__btn ' + (this.getAttribute('btn-class') || '')).trim();
    btn.textContent = this._icon ? '⧉' : this._idle;
    btn.addEventListener('click', () => this._copy());

    this.textContent = '';
    this.appendChild(btn);
    this._btn = btn;
  }

  disconnectedCallback() { clearTimeout(this._timer); }

  get value() {
    return this._value != null ? this._value : (this.getAttribute('value') || '');
  }
  set value(v) { this._value = v == null ? '' : String(v); }

  async _copy() {
    try {
      await navigator.clipboard.writeText(this.value);
      this._showCopied();
      this.dispatchEvent(new CustomEvent('copy-success', { bubbles: true }));
    } catch (error) {
      const ev = new CustomEvent('copy-error', {
        bubbles: true, cancelable: true, detail: { error },
      });
      this.dispatchEvent(ev);
      if (!ev.defaultPrevented) console.warn('copy-button: clipboard write failed', error);
    }
  }

  _showCopied() {
    clearTimeout(this._timer);
    this.classList.add('copied');
    this._btn.setAttribute('aria-label', 'Copied');
    this._btn.textContent = this._icon ? '✓' : '✓ Copied';
    this._timer = setTimeout(() => {
      this.classList.remove('copied');
      this._btn.removeAttribute('aria-label');
      this._btn.textContent = this._icon ? '⧉' : this._idle;
    }, COPIED_RESET_MS);
  }
}

if (!customElements.get('copy-button')) {
  customElements.define('copy-button', CopyButton);
}
