/**
 * True when `header` is `Bearer <expected>`. Both sides are hashed first so the comparison is
 * constant-time and does not leak the key's length. An unset or empty `expected` never matches.
 */
export async function bearerMatches(header: string | null, expected: string | undefined): Promise<boolean> {
  if (!expected || !header) return false;
  const m = /^Bearer\s+(.+)$/i.exec(header.trim());
  if (!m) return false;
  const enc = new TextEncoder();
  const [a, b] = await Promise.all([
    crypto.subtle.digest('SHA-256', enc.encode(m[1])),
    crypto.subtle.digest('SHA-256', enc.encode(expected)),
  ]);
  return crypto.subtle.timingSafeEqual(a, b);
}
