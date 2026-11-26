import { newWebApplicationRecordId, prependWebApplicationBootstrap } from './web_application_preview_bridge.mjs';

function installFixtureData(collectionNames, newRecordId) {
  const collections = new Map(collectionNames.map(name => [name, new Map()]));
  Object.defineProperty(window, 'aivexusData', { value: Object.freeze({
    newRecordId,
    async request({ action, collection, recordId, version, data, after }) {
      const records = collections.get(collection);
      if (!records) throw new Error('collection_not_found');
      if (action === 'list') {
        const page = [...records.values()].filter(record => !after || record.recordId > after)
          .sort((a, b) => a.recordId.localeCompare(b.recordId)).slice(0, 51);
        const result = page.slice(0, 50);
        return { version: 1, ok: true, records: structuredClone(result),
          nextRecordId: page.length > 50 ? result.at(-1).recordId : null };
      }
      const old = records.get(recordId);
      if (action === 'delete' && old?.version === version && old) {
        records.delete(recordId);
        return { version: 1, ok: true, recordId, deleted: true };
      }
      if (!(action === 'create' && !old) && !(action === 'update' && old && old.version === version)) {
        throw new Error('record_conflict');
      }
      const record = { recordId, version: (old?.version ?? 0) + 1, data: structuredClone(data) };
      records.set(recordId, record);
      return { version: 1, ok: true, record: structuredClone(record) };
    },
  }) });
}

export function addFixtureWebApplicationData(html, runtime) {
  if (!runtime) return html;
  const names = runtime.collections.map(collection => collection.name);
  return prependWebApplicationBootstrap(html,
    `(${installFixtureData.toString()})(${JSON.stringify(names)},${newWebApplicationRecordId.toString()})`);
}
