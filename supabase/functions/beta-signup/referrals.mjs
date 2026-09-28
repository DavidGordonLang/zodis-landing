// Canonical self-reported sources. Keep values stable across form and database.
export const referralLabels = Object.freeze({
  reddit: 'Reddit',
  instagram: 'Instagram',
  facebook: 'Facebook',
  tiktok: 'TikTok',
  google_search: 'Google / web search',
  friend_family: 'Friend or family',
  language_community: 'Lithuanian or language-learning community',
  previous_beta: 'Already knew about Žodis / previous beta',
  other: 'Other',
});

export function parseReferral(source, rawDetail) {
  if (typeof source !== 'string' || !Object.hasOwn(referralLabels, source)) return null;
  if (rawDetail != null && typeof rawDetail !== 'string') return null;
  const detail = typeof rawDetail === 'string' ? rawDetail.replace(/\s+/g, ' ').trim() : '';
  if (detail.length > 200 || (source !== 'other' && detail)) return null;
  return {
    source,
    detail: detail || null,
    note: referralLabels[source] + (detail ? ': ' + detail : ''),
  };
}
