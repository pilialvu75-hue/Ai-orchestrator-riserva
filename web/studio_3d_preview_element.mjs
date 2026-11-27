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
        <label hidden>Revisione salvata <select></select></label>
        <a data-file="stl" hidden>Scarica STL</a> <a data-file="scad" hidden>Scarica SCAD</a>
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
    const history = root.querySelector('select');
    const projectId = this.getAttribute('project-id');
    const requests = new AbortController();
    this.requests = requests;
    let loadNumber = 0;
    const links = root.querySelectorAll('a[data-file]');

    function endpoint(file, revisionId) {
      const query = new URLSearchParams({ projectId, file });
      if (revisionId) query.set('revisionId', revisionId);
      return '/api/cantiere/cad/revision?' + query;
    }

    async function read(file, revisionId) {
      const response = await fetch(endpoint(file, revisionId), {
        redirect: 'error', cache: 'no-store', signal: requests.signal,
      });
      if (!response.ok) throw new Error('CAD resource unavailable');
      return response;
    }

    const show = source => {
      this.disposePreview = mountStudioStlPreview(canvas, source, status);
      canvas.hidden = false;
    };
    const reset = () => {
      this.disposePreview?.();
      canvas.hidden = true;
      for (const link of links) link.hidden = true;
      return ++loadNumber;
    };

    const selectRevision = async () => {
      const version = reset();
      const revisionId = history.value;
      status.textContent = 'Caricamento della revisione…';
      try {
        const response = await read('stl', revisionId);
        const source = await response.text();
        if (version !== loadNumber || requests.signal.aborted) return;
        show(source);
        for (const link of links) {
          link.href = endpoint(link.dataset.file, revisionId);
          link.hidden = false;
        }
      } catch {
        if (version === loadNumber && !requests.signal.aborted) {
          status.textContent = 'Impossibile aprire la revisione CAD.';
        }
      }
    };

    if (projectId) {
      history.addEventListener('change', selectRevision);
      read('history').then(response => response.json()).then(({ revisions }) => {
        if (requests.signal.aborted || !revisions.length) return;
        for (const { revisionId, revisionNumber } of revisions) {
          history.add(new Option('Revisione ' + revisionNumber, revisionId));
        }
        history.parentElement.hidden = false;
        if (!loadNumber) return selectRevision();
        history.selectedIndex = -1;
      }).catch(() => {
        if (!loadNumber && !requests.signal.aborted) {
          status.textContent = 'Cronologia delle revisioni non disponibile.';
        }
      });
    }
    canvas.hidden = true;
    input.addEventListener('change', async () => {
      const file = input.files[0];
      history.selectedIndex = -1;
      const version = reset();
      status.textContent = '';
      if (!file) return;
      try {
        if (file.size > 131072) throw new Error('STL too large');
        const source = await file.text();
        if (version !== loadNumber || requests.signal.aborted) return;
        show(source);
      } catch {
        if (version === loadNumber && !requests.signal.aborted) status.textContent = 'Impossibile leggere il file STL ASCII.';
      }
    });
  }

  disconnectedCallback() {
    this.requests?.abort();
    this.disposePreview?.();
  }
}

customElements.define('aivexus-stl-preview', AivexusStlPreview);