import { mountStudioStlPreview } from './studio_3d_preview.mjs';

class AivexusStlPreview extends HTMLElement {
  connectedCallback() {
    const root = this.shadowRoot ?? this.attachShadow({ mode: 'open' });
    root.innerHTML = `
      <style>
        :host { display: block; overflow: auto; color: #e5edf5; background: #111822; font: 16px system-ui; }
        section { box-sizing: border-box; max-width: 900px; margin: auto; padding: 16px; }
        output { display: block; min-height: 1.5em; margin: 12px 0; }
        canvas[hidden] { display: none; }
        canvas { width: 100%; height: auto; display: block; touch-action: none; }
      </style>
      <section>
        <label>File STL <input type="file" accept=".stl,model/stl"></label>
        <output role="status"></output>
        <canvas width="800" height="560" tabindex="0" aria-label="Anteprima 3D"
          aria-describedby="controls"></canvas>
        <p id="controls">Trascina per ruotare, usa Maiusc per spostare la vista.
          Usa la rotella o i tasti + e − per lo zoom.</p>
      </section>
    `;
    const input = root.querySelector('input');
    const status = root.querySelector('output');
    const canvas = root.querySelector('canvas');
    canvas.hidden = true;
    input.addEventListener('change', async () => {
      const file = input.files[0];
      this.disposePreview?.();
      canvas.hidden = true;
      status.textContent = '';
      if (!file) return;
      try {
        if (file.size > 131072) throw new Error('STL too large');
        const source = await file.text();
        if (!input.isConnected || input.files[0] !== file) return;
        this.disposePreview = mountStudioStlPreview(canvas, source, status);
        canvas.hidden = false;
      } catch {
        if (input.files[0] === file) status.textContent = 'Impossibile leggere il file STL ASCII.';
      }
    });
  }

  disconnectedCallback() {
    this.disposePreview?.();
  }
}

customElements.define('aivexus-stl-preview', AivexusStlPreview);