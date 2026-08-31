/** 去除 Markdown code fence 并清理首尾空白（对齐 AccountSnapshotImporter.prepare）。 */
export function prepareAccountText(text: string): { text: string; removedCodeFence: boolean } {
  const trimmed = text.trim();
  const lines = trimmed.split('\n');
  if (
    lines.length >= 3 &&
    lines[0]!.trim().startsWith('```') &&
    lines.at(-1)!.trim() === '```'
  ) {
    return {
      text: lines.slice(1, -1).join('\n').trim(),
      removedCodeFence: true,
    };
  }
  return { text: trimmed, removedCodeFence: false };
}
