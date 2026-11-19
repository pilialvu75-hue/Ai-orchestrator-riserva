export function validateWebApplicationChecks(value) {
  if (!Array.isArray(value) || value.length < 1 || value.length > 16) return null;
  const checks = [];
  for (const check of value) {
    const { action, selector, value: text } = check ?? {};
    if (typeof selector !== 'string' || !selector.trim() || selector.length > 240 || !selector.isWellFormed()) return null;
    if (action === 'click') {
      checks.push({ action, selector });
    } else if ((action === 'fill' || action === 'text') && typeof text === 'string' &&
        text.length <= 600 && text.isWellFormed() && (action === 'fill' || text.length > 0)) {
      checks.push({ action, selector, value: text });
    } else {
      return null;
    }
  }
  return checks.some(check => check.action === 'text') ? checks : null;
}
