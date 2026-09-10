import { useEffect, useRef } from 'react';

import type {
  TrackerBaseDto,
  VillageItemStateDto,
  VillageNextUpgradeDto,
} from '@coc-helper/contracts';

import { availabilityLabel } from '../overview-session';
import {
  authoritativeLevelStatus,
  durationStateLabel,
  formatDurationSeconds,
  levelMissingNote,
  levelTransitionText,
  primaryLevelAssets,
  requirementLabel,
} from '../village-detail-session';
import { AssetImage } from './AssetImage';

export function LevelDetailSheet(props: {
  readonly item: VillageItemStateDto;
  readonly catalogVersion: string | null;
  readonly onClose: () => void;
  readonly returnFocusTo?: HTMLElement | null;
}) {
  const dialogRef = useRef<HTMLDivElement | null>(null);
  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (event.key === 'Escape') {
        props.onClose();
        return;
      }
      if (event.key !== 'Tab') {
        return;
      }
      const dialog = dialogRef.current;
      if (dialog === null) {
        return;
      }
      const focusables = Array.from(
        dialog.querySelectorAll<HTMLElement>(
          'button, [href], input, select, textarea, [tabindex]:not([tabindex="-1"])',
        ),
      ).filter((el) => (el as { readonly disabled?: boolean }).disabled !== true);
      if (focusables.length === 0) {
        event.preventDefault();
        return;
      }
      const first = focusables[0] as HTMLElement;
      const last = focusables[focusables.length - 1] as HTMLElement;
      const active = document.activeElement as HTMLElement | null;
      if (event.shiftKey) {
        if (active === first || (active !== null && !dialog.contains(active))) {
          event.preventDefault();
          last.focus();
        }
      } else {
        if (active === last || (active !== null && !dialog.contains(active))) {
          event.preventDefault();
          first.focus();
        }
      }
    };
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
  }, [props.onClose]);
  useEffect(() => {
    return () => {
      props.returnFocusTo?.focus();
    };
  }, [props.returnFocusTo]);
  // NOTE: props.onClose identity — AppShell/VillageDetail pass inline closures; effect re-subscribes per render. Acceptable (add/remove symmetric, no leak). Do NOT lift into useCallback requirements.
  // 等级/升级/时长一律读 effective 有效视图（Main 侧已按 sidecar 算好，无 sidecar
  // 时回退 raw），与状态同源，禁止混用 raw currentLevel/nextLevel/nextUpgrade。
  const upgrade = upgradeText(props.item.effectiveNextUpgrade, props.item.base);
  const availability = availabilityLabel(props.item.availability);
  const status = authoritativeLevelStatus(props.item);
  const note = levelMissingNote(props.item);
  return (
    <div className="sheet-overlay" onClick={props.onClose}>
      <div
        ref={dialogRef}
        className="level-sheet"
        role="dialog"
        aria-modal="true"
        aria-label={`${props.item.name}等级详情`}
        onClick={(event) => event.stopPropagation()}
      >
        <div className="sheet-header">
          <AssetImage
            catalogVersion={props.catalogVersion}
            candidates={primaryLevelAssets(props.item)}
            size={40}
            className="item-icon"
            fallbackNode={<span className="item-icon-missing">图标缺失</span>}
          />
          <div>
            <h2>{props.item.name}</h2>
            <p className="muted">
              {levelTransitionText(
                props.item.effectiveCurrentLevel,
                props.item.effectiveTargetLevel,
              )}{' '}
              · {status}
            </p>
          </div>
        </div>
        <p>状态：{status}</p>
        {note !== null ? <p>说明：{note}</p> : null}
        {upgrade !== null ? <p>升级：{upgrade}</p> : null}
        <p>时长：{durationStateLabel(props.item.effectiveNextLevelDurationState)}</p>
        {availability !== null ? <p>目录：{availability}</p> : null}
        {props.item.maxLevel !== null ? (
          <p>
            上限：最高 {props.item.maxLevel} 级
            {props.item.currentStageMaxLevel !== null
              ? `（当前阶段最高 ${props.item.currentStageMaxLevel} 级）`
              : ''}
          </p>
        ) : null}
        <button type="button" autoFocus onClick={props.onClose}>
          关闭
        </button>
      </div>
    </div>
  );
}

function upgradeText(
  nextUpgrade: VillageNextUpgradeDto | null,
  base: TrackerBaseDto,
): string | null {
  if (nextUpgrade === null) {
    return null;
  }
  switch (nextUpgrade.kind) {
    case 'available': {
      const dur = formatUpgradeDuration(nextUpgrade.durationSeconds, '时长');
      return `下一级 ${nextUpgrade.level} 级可升级${dur === null ? '' : `（${dur}）`}`;
    }
    case 'requires': {
      const joined = nextUpgrade.requirements.map((req) => requirementLabel(req, base)).join(' · ');
      const cond = nextUpgrade.requirements.length > 0 ? ` 解锁条件：${joined}` : '';
      const ref = formatUpgradeDuration(nextUpgrade.referenceDurationSeconds, '参考时长');
      return `下一级 ${nextUpgrade.nextLevel} 级${cond}${ref === null ? '' : `（${ref}）`}`;
    }
    case 'globalMaxed':
      return '已满级';
    case 'inProgressFact': {
      const dur = formatUpgradeDuration(nextUpgrade.durationSeconds, '时长');
      return `正在升至 ${nextUpgrade.level} 级${dur === null ? '' : `（${dur}）`}`;
    }
    case 'unverified':
      return '未验证';
    case 'unknown':
      return '未知';
    default: {
      const exhaustive: never = nextUpgrade;
      throw new Error(`未知升级状态：${String(exhaustive)}`);
    }
  }
}

/** 升级数值时长：null 表无时长（调用方不渲染），0 表即时升级。 */
function formatUpgradeDuration(seconds: number | null, label: string): string | null {
  if (seconds === null) {
    return null;
  }
  if (seconds === 0) {
    return `${label} 即时`;
  }
  return `${label}${formatDurationSeconds(seconds)}`;
}
