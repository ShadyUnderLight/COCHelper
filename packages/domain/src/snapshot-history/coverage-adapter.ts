import { parseJson } from '@coc-helper/wire';

import { prepareAccountText } from '../account/prepare';
import type { AccountSnapshot } from '../account/types';
import {
  SNAPSHOT_HISTORY_ALL_SECTIONS,
  SNAPSHOT_COVERAGE_CONTRACT_FIELD,
} from './known-sections';
import type { SnapshotCoverageProof } from './types';
import { isWellFormedCoverageDeclaration } from './types';

export function coverageProofsForSnapshot(
  snapshot: AccountSnapshot,
): Record<string, SnapshotCoverageProof> {
  const fallback = '账号 JSON 未声明 section 完整性协议(缺少顶层 coverage 字段)。';
  const topLevel = tryTopLevelObject(snapshot.originalText);
  if (topLevel === undefined) {
    return unavailableProofs(fallback);
  }
  const rawCoverage = topLevel[SNAPSHOT_COVERAGE_CONTRACT_FIELD];
  if (rawCoverage === undefined) {
    return unavailableProofs(fallback);
  }
  if (typeof rawCoverage !== 'object' || rawCoverage === null || Array.isArray(rawCoverage)) {
    return unavailableProofs('账号 JSON 顶层 coverage 字段类型无效，无法作为完整性协议使用。');
  }

  const proofs: Record<string, SnapshotCoverageProof> = {};
  for (const section of [...SNAPSHOT_HISTORY_ALL_SECTIONS].sort()) {
    const declaration = (rawCoverage as Record<string, unknown>)[section];
    if (declaration === undefined) {
      proofs[section] = {
        kind: 'unavailable',
        reason: `来源未声明 section 的完整性：${section}。`,
      };
      continue;
    }
    proofs[section] = decodeCoverageDeclaration(declaration, section);
  }
  return proofs;
}

function unavailableProofs(reason: string): Record<string, SnapshotCoverageProof> {
  const proofs: Record<string, SnapshotCoverageProof> = {};
  for (const section of [...SNAPSHOT_HISTORY_ALL_SECTIONS].sort()) {
    proofs[section] = { kind: 'unavailable', reason };
  }
  return proofs;
}

function decodeCoverageDeclaration(declaration: unknown, section: string): SnapshotCoverageProof {
  if (
    typeof declaration !== 'object' ||
    declaration === null ||
    Array.isArray(declaration) ||
    typeof (declaration as Record<string, unknown>).kind !== 'string'
  ) {
    return {
      kind: 'unavailable',
      reason: `section 完整性声明无法解析：${section}。`,
    };
  }
  const object = declaration as Record<string, unknown>;
  switch (object.kind) {
    case 'unavailable': {
      const reason = object.reason;
      if (typeof reason !== 'string') {
        return {
          kind: 'unavailable',
          reason: `section 完整性声明不可解码，按无证明处理：${section}。`,
        };
      }
      return { kind: 'unavailable', reason };
    }
    case 'verified':
      return {
        kind: 'unavailable',
        reason: `粘贴 JSON 不能声明已验证完整性，按无证明处理：${section}。`,
      };
    case 'authoritative':
    case 'declared': {
      const source = object.source;
      const version = object.version;
      if (typeof source !== 'string' || typeof version !== 'string') {
        return {
          kind: 'unavailable',
          reason: `section 完整性声明不可解码，按无证明处理：${section}。`,
        };
      }
      const expectedCount =
        object.expectedCount === undefined ? null : (object.expectedCount as number);
      const proof: SnapshotCoverageProof =
        object.kind === 'authoritative'
          ? { kind: 'legacyAuthoritative', source, version, expectedCount }
          : { kind: 'declared', source, version, expectedCount };
      if (!isWellFormedCoverageDeclaration(proof)) {
        return {
          kind: 'unavailable',
          reason: `section 完整性声明格式无效，按无证明处理：${section}。`,
        };
      }
      return proof;
    }
    default:
      return {
        kind: 'unavailable',
        reason: `section 完整性声明类型无效，按无证明处理：${section}。`,
      };
  }
}

function tryTopLevelObject(text: string): Record<string, unknown> | undefined {
  const prepared = prepareAccountText(text).text;
  try {
    const parsed = parseJson(prepared);
    if (parsed.kind !== 'object') {
      return undefined;
    }
    const result: Record<string, unknown> = {};
    for (const key of Object.keys(parsed.fields)) {
      result[key] = canonicalJsonValueToUnknown(parsed.fields[key]!);
    }
    return result;
  } catch {
    return undefined;
  }
}

function canonicalJsonValueToUnknown(value: import('@coc-helper/wire').CanonicalJsonValue): unknown {
  switch (value.kind) {
    case 'null':
      return null;
    case 'bool':
      return value.value;
    case 'number':
      return Number(value.value);
    case 'string':
      return value.value;
    case 'array':
      return value.items.map(canonicalJsonValueToUnknown);
    case 'object': {
      const result: Record<string, unknown> = {};
      for (const key of Object.keys(value.fields)) {
        result[key] = canonicalJsonValueToUnknown(value.fields[key]!);
      }
      return result;
    }
  }
}
