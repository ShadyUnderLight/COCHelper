import type { DiagnosticsSnapshotPayload } from '@coc-helper/contracts';

import {
  diagnosticsApplicationLabel,
  diagnosticsResourceErrorText,
  type DiagnosticsState,
} from '../diagnostics-session';
import { resourceData } from '../resource-state';

export function DiagnosticsPanel(props: {
  readonly state: DiagnosticsState;
  readonly onRetry: () => void;
}) {
  const payload = resourceData(props.state);
  const errorText = diagnosticsResourceErrorText(props.state);

  if (payload === null) {
    return (
      <section className="info-panel" aria-label="诊断">
        <h2>Diagnostics</h2>
        {props.state.kind === 'failed' ? (
          <>
            <p className="error-text" role="alert">
              {errorText ?? '诊断加载失败。'}
            </p>
            <button type="button" onClick={props.onRetry}>
              重试
            </button>
          </>
        ) : (
          <p className="muted">正在加载诊断信息…</p>
        )}
      </section>
    );
  }

  return (
    <section className="info-panel" aria-label="诊断">
      <div className="info-panel-heading">
        <div>
          <h2>Diagnostics</h2>
          <p className="muted">仅显示脱敏后的应用状态，不包含凭据或原始网络数据。</p>
        </div>
        <button type="button" onClick={props.onRetry}>
          刷新诊断
        </button>
      </div>
      {errorText !== null ? (
        <p className="notice-text" role="alert">
          {errorText}
        </p>
      ) : props.state.kind === 'refreshing' ? (
        <p className="muted">正在刷新诊断…</p>
      ) : null}
      <DiagnosticsDetails payload={payload} />
    </section>
  );
}

function DiagnosticsDetails({ payload }: { readonly payload: DiagnosticsSnapshotPayload }) {
  const application = payload.application;
  const catalog = payload.catalog;
  const token = payload.token;
  return (
    <div className="diagnostics-sections">
      <section>
        <h3>应用</h3>
        <dl className="diagnostics-grid">
          <DiagnosticRow label="名称" value={payload.app.name} />
          <DiagnosticRow label="版本" value={payload.app.version} />
          <DiagnosticRow
            label="当前状态"
            value={diagnosticsApplicationLabel(application.availability)}
          />
          <DiagnosticRow label="Village Store" value={application.villageStatus} />
          <DiagnosticRow label="Generation" value={String(application.generation)} />
          <DiagnosticRow label="当前村庄" value={application.selectedVillageName ?? '未选择'} />
          <DiagnosticRow
            label="Pending journal"
            value={application.hasPendingJournal ? '有' : '无'}
          />
          <DiagnosticRow label="可写" value={application.canWrite ? '是' : '否'} />
        </dl>
      </section>

      <section>
        <h3>运行环境</h3>
        <dl className="diagnostics-grid">
          <DiagnosticRow label="Electron" value={payload.runtime.electron} />
          <DiagnosticRow label="Node" value={payload.runtime.node} />
          <DiagnosticRow label="Chrome" value={payload.runtime.chrome} />
          <DiagnosticRow label="平台" value={payload.runtime.platform} />
          <DiagnosticRow label="架构" value={payload.runtime.arch} />
        </dl>
      </section>

      <section>
        <h3>服务状态</h3>
        <dl className="diagnostics-grid">
          <DiagnosticRow
            label="Catalog"
            value={`${catalog.status === 'available' ? '可用' : '不可用'}${catalog.version === null ? '' : ` · ${catalog.version}`}`}
          />
          <DiagnosticRow label="Manual 存储" value={manualStatusLabel(payload.manual.status)} />
          <DiagnosticRow label="Official endpoint" value="仅由 Main 进程访问" />
          <DiagnosticRow label="Authorization" value="仅由 Main 进程处理" />
          <DiagnosticRow label="原始响应" value="不暴露给 Renderer" />
          <DiagnosticRow label="Token 存储" value={tokenStorageLabel(token)} />
        </dl>
      </section>
    </div>
  );
}

function DiagnosticRow(props: { readonly label: string; readonly value: string }) {
  return (
    <div className="diagnostic-row">
      <dt>{props.label}</dt>
      <dd>{props.value}</dd>
    </div>
  );
}

function tokenStorageLabel(payload: DiagnosticsSnapshotPayload['token']): string {
  if (payload.storage === 'decryptFailed') {
    return '解密失败';
  }
  if (payload.storage === 'unavailable') {
    return '不可用';
  }
  return payload.configured ? '已配置' : '未配置';
}

function manualStatusLabel(status: DiagnosticsSnapshotPayload['manual']['status']): string {
  switch (status) {
    case 'missing':
      return '缺失';
    case 'available':
      return '可用';
    case 'empty':
      return '空';
    case 'unavailable':
      return '不可用';
    case 'migrationRequired':
      return '需要迁移';
    default: {
      const exhaustive: never = status;
      throw new Error(`未知 Manual 状态：${String(exhaustive)}`);
    }
  }
}
