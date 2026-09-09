import { useEffect, useState } from 'react';

import type {
  TrackerBaseDto,
  VillageItemStateDto,
  VillageNextUpgradeDto,
} from '@coc-helper/contracts';

import { overviewAssetUrl } from '../asset-url';
import { availabilityLabel, effectiveStatusLabel, statusLabel } from '../overview-session';
import {
  durationStateLabel,
  formatDurationSeconds,
  levelTransitionText,
  primaryLevelAsset,
  requirementLabel,
} from '../village-detail-session';

export function LevelDetailSheet(props: {
  readonly item: VillageItemStateDto;
  readonly catalogVersion: string | null;
  readonly onClose: () => void;
}) {
  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (event.key === 'Escape') props.onClose();
    };
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
  }, [props.onClose]);
  // NOTE: props.onClose identity — AppShell/VillageDetail pass inline closures; effect re-subscribes per render. Acceptable (add/remove symmetric, no leak). Do NOT lift into useCallback requirements.
  const upgrade = upgradeText(props.item.nextUpgrade, props.item.base);
  const availability = availabilityLabel(props.item.availability);
  return (
    <div className="sheet-overlay" onClick={props.onClose}>
      <div
        className="level-sheet"
        role="dialog"
        aria-modal="true"
        aria-label={`${props.item.name}等级详情`}
        onClick={(event) => event.stopPropagation()}
      >
        <div className="sheet-header">
          <SheetIcon item={props.item} catalogVersion={props.catalogVersion} />
          <div>
            <h2>{props.item.name}</h2>
            <p className="muted">
              {levelTransitionText(props.item.currentLevel, props.item.nextLevel)} ·{' '}
              {statusText(props.item)}
            </p>
          </div>
        </div>
        <p>状态：{statusText(props.item)}</p>
        {upgrade !== null ? <p>升级：{upgrade}</p> : null}
        <p>时长：{durationStateLabel(props.item.nextLevelDurationState)}</p>
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

function statusText(item: VillageItemStateDto): string {
  const effective = effectiveStatusLabel(item.effectiveStatus);
  return effective === null
    ? statusLabel(item.status)
    : `${statusLabel(item.status)} · ${effective}`;
}

function upgradeText(
  nextUpgrade: VillageNextUpgradeDto | null,
  base: TrackerBaseDto,
): string | null {
  if (nextUpgrade === null) {
    return null;
  }
  switch (nextUpgrade.kind) {
    case 'available':
      return `下一级 ${nextUpgrade.level} 级可升级${
        nextUpgrade.durationSeconds === null
          ? ''
          : `（时长 ${formatDurationSeconds(nextUpgrade.durationSeconds)}）`
      }`;
    case 'requires': {
      const joined = nextUpgrade.requirements.map((req) => requirementLabel(req, base)).join(' · ');
      const cond = nextUpgrade.requirements.length > 0 ? ` 解锁条件：${joined}` : '';
      const ref =
        nextUpgrade.referenceDurationSeconds === null
          ? ''
          : `（参考时长 ${formatDurationSeconds(nextUpgrade.referenceDurationSeconds)}）`;
      return `下一级 ${nextUpgrade.nextLevel} 级${cond}${ref}`;
    }
    case 'globalMaxed':
      return '已满级';
    case 'inProgressFact':
      return `正在升至 ${nextUpgrade.level} 级${
        nextUpgrade.durationSeconds === null
          ? ''
          : `（时长 ${formatDurationSeconds(nextUpgrade.durationSeconds)}）`
      }`;
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

function SheetIcon(props: {
  readonly item: VillageItemStateDto;
  readonly catalogVersion: string | null;
}) {
  const [failed, setFailed] = useState(false);
  const url = failed ? null : overviewAssetUrl(props.catalogVersion, primaryLevelAsset(props.item));
  if (url === null) {
    return <span className="item-icon-missing">图标缺失</span>;
  }
  return (
    <img
      className="item-icon"
      src={url}
      alt=""
      width={40}
      height={40}
      onError={() => setFailed(true)}
    />
  );
}
