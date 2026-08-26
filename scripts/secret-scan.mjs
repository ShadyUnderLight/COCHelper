import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import path from 'node:path';

export const SECRET_PATTERNS = [
  { re: /-----BEGIN [A-Z ]*PRIVATE KEY-----/, message: '私钥块' },
  { re: /Authorization:\s*Bearer\s+\S+/i, message: 'Authorization Bearer' },
  { re: /eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}/, message: 'JWT' },
  { re: /_authToken\s*=\s*\S+/i, message: 'npm _authToken' },
  { re: /\bnpm_[A-Za-z0-9]{20,}\b/, message: 'npm token' },
  { re: /\bghp_[A-Za-z0-9]{36}\b/, message: 'GitHub PAT' },
  { re: /\bgithub_pat_[A-Za-z0-9_]{20,}\b/, message: 'GitHub fine-grained PAT' },
  { re: /\bgho_[A-Za-z0-9]{36}\b/, message: 'GitHub OAuth token' },
  { re: /\bghu_[A-Za-z0-9]{36}\b/, message: 'GitHub user-to-server token' },
  { re: /\bghs_[A-Za-z0-9]{36}\b/, message: 'GitHub server-to-server token' },
  { re: /\bghr_[A-Za-z0-9]{36}\b/, message: 'GitHub refresh token' },
];

const BINARY_EXTENSIONS = new Set([
  'png',
  'jpg',
  'jpeg',
  'gif',
  'webp',
  'icns',
  'ico',
  'zip',
  'gz',
  'br',
  'wasm',
  'pdf',
  'ttf',
  'otf',
  'woff',
  'woff2',
  'mp4',
  'mov',
  'apk',
  'bin',
]);

export function isSkippedPath(relativePath) {
  const ext = path.extname(relativePath).slice(1).toLowerCase();
  return BINARY_EXTENSIONS.has(ext);
}

export function listTrackedFiles(root) {
  const stdout = execFileSync('git', ['ls-files', '-z'], { cwd: root });
  return stdout
    .toString('utf8')
    .split('\0')
    .filter((file) => file.length > 0 && !isSkippedPath(file));
}

export function findSecretHits(text, relativePath) {
  const hits = [];
  for (const pattern of SECRET_PATTERNS) {
    if (pattern.re.test(text)) {
      hits.push(`${relativePath} → ${pattern.message}`);
    }
  }
  return hits;
}

export function scanFileBuffer(buf, relativePath) {
  return findSecretHits(buf.toString('utf8'), relativePath);
}

export function scanTrackedFiles(root) {
  const hits = [];
  for (const relativePath of listTrackedFiles(root)) {
    const absolute = path.join(root, relativePath);
    let buf;
    try {
      buf = readFileSync(absolute);
    } catch {
      continue;
    }
    hits.push(...scanFileBuffer(buf, relativePath));
  }
  return hits;
}
