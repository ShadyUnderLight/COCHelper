import { redactIpcDiagnosticText } from '@coc-helper/contracts';

/** 清洗可展示错误文本，禁止 URL、凭据和控制字符进入 IPC envelope。 */
export function redactDiagnosticText(value: string): string {
  return redactIpcDiagnosticText(value);
}
