const list = value => String(value || '').split(',').map(item => item.trim()).filter(Boolean);

export function settings(env) {
  const api = new URL(env.UPSTREAM_API);
  const speech = new URL(env.UPSTREAM_SPEECH);
  if (api.protocol !== 'https:' || speech.protocol !== 'wss:' ||
      [api, speech].some(url => url.username || url.password || url.search || url.hash)) {
    throw Error('configuration');
  }
  const origins = list(env.ALLOWED_ORIGINS);
  for (const origin of origins) {
    const url = new URL(origin);
    if (!['http:', 'https:'].includes(url.protocol) || url.origin !== origin) {
      throw Error('configuration');
    }
  }
  return {api, speech, origins};
}
