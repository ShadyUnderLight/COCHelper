/**
 * Renderer 路由：只描述「当前看哪个页面」，不承载业务数据。
 */
import type { TrackerBaseDto } from '@coc-helper/contracts';

export type OfficialSection = 'player' | 'clan' | 'currentWar' | 'warLog' | 'capitalRaid';

export type ManualSection = 'upgrade' | 'queue' | 'reconciliation';

export type InfoSection = 'diagnostics' | 'tokenSettings';

export type AppRoute =
  | { readonly kind: 'import' }
  | { readonly kind: 'overview' }
  | { readonly kind: 'villageDetail'; readonly villageId: string; readonly base: TrackerBaseDto }
  | { readonly kind: 'official'; readonly section: OfficialSection }
  | { readonly kind: 'manual'; readonly section: ManualSection }
  | { readonly kind: 'info'; readonly section: InfoSection };

export const INITIAL_ROUTE: AppRoute = { kind: 'import' };

export type PrimaryTab = 'import' | 'overview' | 'detail';

export type NavigateAction =
  | { readonly type: 'navigate'; readonly route: AppRoute }
  | {
      readonly type: 'openVillageDetail';
      readonly villageId: string;
      readonly base?: TrackerBaseDto;
    };

/** 当前三 tab 页面对应的主 tab；official/manual/info 暂映射到 overview 占位。 */
export function primaryTabOfRoute(route: AppRoute): PrimaryTab {
  switch (route.kind) {
    case 'import':
      return 'import';
    case 'overview':
    case 'official':
    case 'manual':
    case 'info':
      return 'overview';
    case 'villageDetail':
      return 'detail';
    default: {
      const exhaustive: never = route;
      throw new Error(`未知路由：${String(exhaustive)}`);
    }
  }
}

export function routeEquals(a: AppRoute, b: AppRoute): boolean {
  if (a.kind !== b.kind) {
    return false;
  }
  switch (a.kind) {
    case 'import':
    case 'overview':
      return true;
    case 'villageDetail':
      return b.kind === 'villageDetail' && a.villageId === b.villageId && a.base === b.base;
    case 'official':
      return b.kind === 'official' && a.section === b.section;
    case 'manual':
      return b.kind === 'manual' && a.section === b.section;
    case 'info':
      return b.kind === 'info' && a.section === b.section;
    default: {
      const exhaustive: never = a;
      throw new Error(`未知路由：${String(exhaustive)}`);
    }
  }
}

export function navigationReducer(state: AppRoute, action: NavigateAction): AppRoute {
  switch (action.type) {
    case 'navigate':
      return action.route;
    case 'openVillageDetail':
      return {
        kind: 'villageDetail',
        villageId: action.villageId,
        base: action.base ?? 'home',
      };
    default: {
      const exhaustive: never = action;
      throw new Error(`未知导航动作：${String(exhaustive)}`);
    }
  }
}
