/** fault replay 独立门禁占位。实现由 E3-01（#275）接入文件存储后填充。 */
export const FAULT_REPLAY_STATUS = 'deferred-e3-01' as const;

export function runFaultReplay(): never {
  throw new Error('fault replay 尚未接入文件存储实现，见 Issue #275 / E3-01。');
}
