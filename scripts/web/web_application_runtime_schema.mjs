const NAME = /^[a-z][a-z0-9_]{0,31}$/;
const TYPES = new Set(['text', 'integer', 'boolean', 'date']);
const RESERVED = new Set(['constructor', 'prototype']);
const isObject = value => !!value && typeof value === 'object' && !Array.isArray(value);
const nameIsValid = value => typeof value === 'string' && NAME.test(value) && !RESERVED.has(value);

export function normalizeWebApplicationRuntime(value) {
  if (!isObject(value) || value.kind !== 'records' || !Array.isArray(value.collections) ||
      value.collections.length < 1 || value.collections.length > 8) return null;
  const collections = [];
  const names = new Set();
  for (const collection of value.collections) {
    const { name, fields } = collection ?? {};
    if (!nameIsValid(name) || names.has(name) || !isObject(fields)) return null;
    const entries = Object.entries(fields).sort(([a], [b]) => a < b ? -1 : a === b ? 0 : 1);
    if (entries.length < 1 || entries.length > 12 ||
        entries.some(([key, type]) => !nameIsValid(key) || !TYPES.has(type))) return null;
    names.add(name);
    collections.push({ name, fields: Object.fromEntries(entries) });
  }
  collections.sort((a, b) => a.name < b.name ? -1 : a.name === b.name ? 0 : 1);
  if (value.integrations === undefined) return { kind: 'records', collections };
  if (!Array.isArray(value.integrations) || value.integrations.length !== 1 ||
      value.integrations[0] !== 'github_repository') return null;
  return { kind: 'records', collections, integrations: ['github_repository'] };
}

const validators = {
  text: value => typeof value === 'string' && value.length <= 500 && value.isWellFormed(),
  integer: value => Number.isSafeInteger(value) && Math.abs(value) <= 1000000000,
  boolean: value => typeof value === 'boolean',
  date(value) {
    if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
    const date = Date.parse(`${value}T00:00:00Z`);
    return Number.isFinite(date) && new Date(date).toISOString().slice(0, 10) === value;
  },
};

export function normalizeWebApplicationRecord(collection, value) {
  if (!isObject(value) || Object.keys(value).length !== Object.keys(collection.fields).length) return null;
  const fields = [];
  for (const [field, type] of Object.entries(collection.fields)) {
    if (!Object.hasOwn(value, field) || !validators[type](value[field])) return null;
    fields.push([field, value[field]]);
  }
  return Object.fromEntries(fields);
}
