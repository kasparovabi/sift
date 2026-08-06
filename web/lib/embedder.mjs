/// Where vectors come from. Sift ships no model of its own, and Anthropic has no embeddings
/// API, so a Claude subscription cannot produce these. What it can use is a model already
/// running on the machine, which keeps the download at zero and the text where it is.

/// The servers worth probing, in the order they are preferred.
export const CANDIDATES = [
  { name: 'Ollama', probe: 'http://127.0.0.1:11434/api/tags',
    embed: 'http://127.0.0.1:11434/api/embed', openAI: false },
  { name: 'LM Studio', probe: 'http://127.0.0.1:1234/v1/models',
    embed: 'http://127.0.0.1:1234/v1/embeddings', openAI: true },
];

/// Vectors from two models are not comparable, so this is stored beside every one and a
/// change throws them away rather than silently mixing two coordinate systems.
export function fingerprint(backend) {
  return `${backend.name}:${backend.model}`;
}

/// A chat model will answer an embedding request on some servers and hand back something that
/// ranks like noise, which is worse than having no semantic search at all.
export function looksLikeEmbeddingModel(name) {
  const lowered = String(name).toLowerCase();
  return ['embed', 'bge', 'gte', 'e5', 'minilm', 'nomic'].some((m) => lowered.includes(m));
}

export function models(body) {
  let object;
  try { object = JSON.parse(body); } catch { return []; }
  if (!object || typeof object !== 'object') return [];
  if (Array.isArray(object.models)) {
    return object.models.map((r) => r?.name || r?.model).filter(Boolean);
  }
  if (Array.isArray(object.data)) return object.data.map((r) => r?.id).filter(Boolean);
  return [];
}

/// Both shapes, read leniently. A server that puts numbers in the right place is good enough.
export function vectors(body, openAICompatible) {
  let object;
  try { object = JSON.parse(body); } catch { throw new Error('not JSON'); }
  if (!object || typeof object !== 'object') throw new Error('not an object');

  if (openAICompatible) {
    if (!Array.isArray(object.data)) throw new Error('no data array');
    return object.data.map((r) => r?.embedding).filter(Array.isArray);
  }
  if (Array.isArray(object.embeddings)) return object.embeddings.filter(Array.isArray);
  // The legacy /api/embeddings answers with one vector under `embedding`.
  if (Array.isArray(object.embedding)) return [object.embedding];
  throw new Error('no embeddings');
}

export async function embed(backend, texts, fetcher = fetch) {
  if (!texts.length) return [];
  const response = await fetcher(backend.embed, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ model: backend.model, input: texts }),
  });
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  return vectors(await response.text(), backend.openAI);
}

/// Finds a model server that is already running. Nothing is installed and nothing downloaded;
/// if none answers, search stays lexical and says so.
export async function discover(fetcher = fetch) {
  for (const candidate of CANDIDATES) {
    try {
      const response = await fetcher(candidate.probe, { signal: AbortSignal.timeout(2000) });
      if (!response.ok) continue;
      const model = models(await response.text()).find(looksLikeEmbeddingModel);
      if (!model) continue;
      return { ...candidate, model };
    } catch { /* nothing is listening there, try the next one */ }
  }
  return null;
}

export function cosine(a, b) {
  const n = Math.min(a.length, b.length);
  if (!n) return 0;
  let dot = 0, na = 0, nb = 0;
  for (let i = 0; i < n; i += 1) { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i]; }
  return na > 0 && nb > 0 ? dot / (Math.sqrt(na) * Math.sqrt(nb)) : 0;
}

export function toBytes(vector) {
  return Buffer.from(new Float32Array(vector).buffer);
}

export function fromBytes(bytes) {
  if (!bytes || bytes.length === 0 || bytes.length % 4 !== 0) return [];
  const copy = Buffer.from(bytes);
  return Array.from(new Float32Array(copy.buffer, copy.byteOffset, copy.length / 4));
}

/// Reciprocal rank fusion. Two rankings that disagree about scale still agree about order, so
/// ranks are what get combined and something both put near the top wins.
export function fuse(lexical, semantic, k = 60) {
  const score = new Map();
  const add = (ids) => ids.forEach((id, i) => score.set(id, (score.get(id) ?? 0) + 1 / (k + i + 1)));
  add(lexical);
  add(semantic);
  return [...score.entries()]
    .sort((a, b) => (b[1] - a[1]) || (a[0] < b[0] ? -1 : 1))
    .map(([id]) => id);
}
