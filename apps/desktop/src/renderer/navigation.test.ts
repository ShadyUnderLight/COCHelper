import { describe, expect, it } from 'vitest';

import {
  INITIAL_ROUTE,
  navigationReducer,
  primaryTabOfRoute,
  routeEquals,
  type AppRoute,
} from './navigation';

describe('navigation', () => {
  it('INITIAL_ROUTE 为 import', () => {
    expect(INITIAL_ROUTE).toEqual({ kind: 'import' });
  });

  it('primaryTabOfRoute 映射主导航 tab', () => {
    expect(primaryTabOfRoute({ kind: 'import' })).toBe('import');
    expect(primaryTabOfRoute({ kind: 'overview' })).toBe('overview');
    expect(primaryTabOfRoute({ kind: 'villageDetail', villageId: 'v1', base: 'home' })).toBe(
      'detail',
    );
    expect(primaryTabOfRoute({ kind: 'official', section: 'player' })).toBe('overview');
    expect(primaryTabOfRoute({ kind: 'info', section: 'diagnostics' })).toBe('info');
  });

  it('routeEquals 区分 villageDetail base', () => {
    const a: AppRoute = { kind: 'villageDetail', villageId: 'v1', base: 'home' };
    const b: AppRoute = { kind: 'villageDetail', villageId: 'v1', base: 'builder' };
    expect(routeEquals(a, a)).toBe(true);
    expect(routeEquals(a, b)).toBe(false);
  });

  it('navigationReducer navigate 替换路由', () => {
    const next = navigationReducer(INITIAL_ROUTE, {
      type: 'navigate',
      route: { kind: 'overview' },
    });
    expect(next).toEqual({ kind: 'overview' });
  });

  it('openVillageDetail 使用稳定 villageId', () => {
    const next = navigationReducer(INITIAL_ROUTE, {
      type: 'openVillageDetail',
      villageId: 'v-uuid',
    });
    expect(next).toEqual({ kind: 'villageDetail', villageId: 'v-uuid', base: 'home' });
  });
});
