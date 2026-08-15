/**
 * PHASE 11-OB PREP · CANONICAL JSON — one spelling per value, so a digest means something.
 *
 * ★ WHY NOT `JSON.stringify`. Object key order in JS follows insertion order, so two structurally
 * identical baselines assembled by different code paths — or by the same code after a harmless
 * reordering of a `jsonb_build_object` — serialize differently and hash differently. A baseline
 * digest that changes when nothing changed is a digest nobody will trust the third time, and an
 * "immutable baseline" nobody trusts is a file, not a control.
 *
 * Rules, all of them deliberate:
 *   · object keys sorted by code unit;
 *   · array ORDER PRESERVED — order is data here (stage markers, censuses), never incidental;
 *   · `undefined` is REFUSED rather than dropped. `JSON.stringify` silently omits it, so a field
 *     that failed to be collected would vanish and the digest would describe a smaller world than
 *     the one intended. Missing must be spelled `null`;
 *   · non-finite numbers refused for the same reason (`NaN` would become `null`);
 *   · functions, symbols and BigInt refused — nothing in a baseline should be one.
 */
import { createHash } from 'node:crypto';

export function canonicalize(value, path = '$') {
  if (value === null) return 'null';
  const t = typeof value;
  if (t === 'undefined') {
    throw new TypeError(`canonicalize: undefined at ${path} — spell a missing value as null`);
  }
  if (t === 'number') {
    if (!Number.isFinite(value)) throw new TypeError(`canonicalize: non-finite number at ${path}`);
    return JSON.stringify(value);
  }
  if (t === 'boolean' || t === 'string') return JSON.stringify(value);
  if (t === 'bigint' || t === 'function' || t === 'symbol') {
    throw new TypeError(`canonicalize: unsupported ${t} at ${path}`);
  }
  if (Array.isArray(value)) {
    return `[${value.map((v, i) => canonicalize(v, `${path}[${i}]`)).join(',')}]`;
  }
  const keys = Object.keys(value).sort();
  return `{${keys.map((k) => `${JSON.stringify(k)}:${canonicalize(value[k], `${path}.${k}`)}`).join(',')}}`;
}

export function sha256Hex(text) {
  return createHash('sha256').update(text, 'utf8').digest('hex');
}

/** The digest of a value's canonical form. The only sanctioned way to hash a baseline or payload. */
export function canonicalDigest(value) {
  return sha256Hex(canonicalize(value));
}
