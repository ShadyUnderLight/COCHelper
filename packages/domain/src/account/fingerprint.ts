// Issue #304：内容 fingerprint 已删除，仅保留 wire 十六进制诊断 ID 掩码
//（非密码学 helper，供测试对比稳定输出）。
export function maskDiagnosticIdsInWireHex(wireHex: string): string {
  const bytes = hexToBytes(wireHex);
  const json = new TextDecoder().decode(bytes);
  const masked = json.replace(
    /"id":"[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}"/g,
    '"id":"<RANDOM_DIAGNOSTIC_UUID>"',
  );
  return bytesToHex(new TextEncoder().encode(masked));
}

function hexToBytes(value: string): Uint8Array {
  const bytes = new Uint8Array(value.length / 2);
  for (let index = 0; index < bytes.length; index += 1) {
    bytes[index] = Number.parseInt(value.slice(index * 2, index * 2 + 2), 16);
  }
  return bytes;
}

function bytesToHex(bytes: Uint8Array): string {
  return [...bytes].map((byte) => byte.toString(16).padStart(2, '0')).join('');
}
