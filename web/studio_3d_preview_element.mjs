import { mountStudioStlPreview } from './studio_3d_preview.mjs';

class AivexusStlPreview extends HTMLElement {
  connectedCallback() {
    const root = this.shadowRoot ?? this.attachShadow({ mode: 'open' });
    root.innerHTML = `
      <style>
        :host { display: block; overflow: auto; color: #e5edf5; background: #111822; font: 16px system-ui; }
        section { box-sizing: border-box; max-width: 900px; margin: auto; padding: 16px; }
        output { display: block; min-height: 1.5em; margin: 12px 0; }
        fieldset { display: flex; flex-wrap: wrap; gap: 12px; margin-bottom: 12px; }
        input[type=number] { width: 5em; }
        canvas[hidden] { display: none; }
        canvas { width: 100%; height: auto; display: block; touch-action: none; }
      </style>
      <section>
        <form hidden>
          <fieldset>
            <legend>Scatola aperta · misure in mm</legend>
            <label>Larghezza <input name="width" type="number" min="0.1" max="500" step="any" value="80" required></label>
            <label>Profondità <input name="depth" type="number" min="0.1" max="500" step="any" value="60" required></label>
            <label>Altezza <input name="height" type="number" min="0.1" max="500" step="any" value="30" required></label>
            <label>Parete <input name="wall" type="number" min="0.1" max="500" step="any" value="2" required></label>
            <label>Fondo <input name="floor" type="number" min="0.1" max="500" step="any" value="3" required></label>
            <button type="submit">Genera revisione CAD</button>
            <div data-edit hidden>
              <label>Modifica della revisione
                <input data-instruction maxlength="160" placeholder="Allarga la scatola di 10 mm">
              </label>
              <button type="submit" data-apply>Applica modifica</button>
            </div>
          </fieldset>
          <button type="button" data-refresh hidden>Aggiorna generazione</button>
          <output data-job role="status"></output>
        </form>
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
    const input = root.querySelector('input[type=file]');
    const status = root.querySelector('output:not([data-job])');
    const canvas = root.querySelector('canvas');
    const history = root.querySelector('select');
    let revisionParameters = new Map();
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
      const parameters = revisionParameters.get(revisionId);
      edit.hidden = !parameters;
      for (const field of fields.querySelectorAll('input[name]')) {
        if (Number.isFinite(parameters?.[field.name])) field.value = parameters[field.name];
      }
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

    const form = root.querySelector('form');
    const fields = form.querySelector('fieldset');
    const edit = form.querySelector('[data-edit]');
    const instructionField = edit.querySelector('input');
    const refresh = form.querySelector('[data-refresh]');
    const jobStatus = form.querySelector('[data-job]');
    const storageKey = 'aivexus.cad.pending.' + projectId;
    let pending;
    let busy = false;
    let historyReady = false;

    function remember(value) {
      pending = value;
      try {
        if (value) sessionStorage.setItem(storageKey, JSON.stringify(value));
        else sessionStorage.removeItem(storageKey);
      } catch { /* workflow remains available in memory */ }
      updateControls();
    }

    function updateControls() {
      fields.disabled = busy || Boolean(pending) || !historyReady;
      refresh.hidden = !pending;
      refresh.disabled = busy;
    }

    async function runJob(action) {
      if (busy || !pending) return;
      busy = true;
      updateControls();
      try {
        const { revisionId, parameters, instruction, baseRevisionId } = pending;
        const request = action === 'start'
          ? { action, projectId, revisionId, baseRevisionId, ...(instruction ? { instruction } : { parameters }) }
          : { action, projectId, revisionId };
        const response = await fetch('/api/cantiere/cad/job', {
          method: 'POST', redirect: 'error', cache: 'no-store', signal: requests.signal,
          headers: { 'content-type': 'application/json' }, body: JSON.stringify(request),
        });
        if (requests.signal.aborted) return;
        if (!response.ok) {
          if ([400, 401, 403, 404, 409].includes(response.status)) remember(null);
          const { error } = await response.json().catch(() => ({}));
          if (error === 'unsupported_cad_instruction') {
            jobStatus.textContent = 'Modifica non riconosciuta. Prova «Allarga la scatola di 10 mm».';
            return;
          }
          throw new Error('CAD job unavailable');
        }
        const { status: state } = await response.json();
        switch (state) {
          case 'verified':
            remember(null);
            jobStatus.textContent = 'Revisione CAD verificata.';
            instructionField.value = '';
            await loadHistory(revisionId);
            break;
          case 'submitted':
          case 'dispatching':
            remember({ ...pending, submitted: true });
            jobStatus.textContent = 'Generazione CAD in corso. Usa Aggiorna generazione per verificarne l’esito.';
            break;
          case 'failed':
          case 'review_required':
            remember(null);
            jobStatus.textContent = state === 'failed'
              ? 'Generazione CAD non riuscita.' : 'Impossibile confermare l’avvio della generazione.';
            break;
          default:
            throw new Error('Invalid CAD job status');
        }
      } catch {
        if (!requests.signal.aborted) jobStatus.textContent = 'Generazione CAD non disponibile. Riprova tra poco.';
      } finally {
        busy = false;
        updateControls();
      }
    }

    async function loadHistory(selectedId) {
      const { revisions } = await (await read('history')).json();
      if (requests.signal.aborted) return;
      revisionParameters = new Map(revisions.map(({ revisionId, parameters }) => [revisionId, parameters]));
      history.replaceChildren(...revisions.map(({ revisionId, revisionNumber }) =>
        new Option('Revisione ' + revisionNumber, revisionId)));
      history.parentElement.hidden = !revisions.length;
      historyReady = true;
      updateControls();
      if (revisions.length && (selectedId || !loadNumber)) {
        if (selectedId) history.value = selectedId;
        await selectRevision();
      } else if (loadNumber) {
        history.selectedIndex = -1;
      }
    }

    if (projectId) {
      form.hidden = false;
      try { pending = JSON.parse(sessionStorage.getItem(storageKey)); } catch { /* browser storage optional */ }
      updateControls();
      history.addEventListener('change', selectRevision);
      form.addEventListener('submit', event => {
        event.preventDefault();
        if (busy || pending || !historyReady) return;
        const baseRevisionId = history.value || history.options[0]?.value || null;
        const isEdit = event.submitter?.hasAttribute('data-apply');
        const instruction = instructionField.value.trim();
        if (isEdit && (!baseRevisionId || !instruction)) {
          jobStatus.textContent = 'Seleziona una revisione e descrivi la modifica.';
          return;
        }
        const input = isEdit ? { instruction } : {
          parameters: Object.fromEntries([...new FormData(form)].map(([name, value]) => [name, Number(value)])),
        };
        remember({ revisionId: crypto.randomUUID(), baseRevisionId, ...input });
        void runJob('start');
      });
      refresh.addEventListener('click', () => void runJob(pending?.submitted ? 'collect' : 'start'));
      loadHistory().catch(() => {
        if (!loadNumber && !requests.signal.aborted) status.textContent = 'Cronologia delle revisioni non disponibile.';
      });
    }
    canvas.hidden = true;
    input.addEventListener('change', async () => {
      const file = input.files[0];
      history.selectedIndex = -1;
      edit.hidden = true;
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