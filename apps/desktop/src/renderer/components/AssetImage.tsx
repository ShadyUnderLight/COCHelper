import { useEffect, useMemo, useState } from 'react';

import type { CatalogAssetRefDto } from '@coc-helper/contracts';

import { overviewAssetUrl } from '../asset-url';

export function AssetImage(props: {
  readonly catalogVersion: string | null;
  readonly candidates: readonly (CatalogAssetRefDto | null)[];
  readonly size: number;
  readonly className: string;
  readonly fallback: 'hide' | 'placeholder';
}) {
  const urls = useMemo(
    () =>
      props.candidates.flatMap((ref) => {
        const url = overviewAssetUrl(props.catalogVersion, ref);
        return url === null ? [] : [url];
      }),
    [props.catalogVersion, props.candidates],
  );
  const urlKey = urls.join('\n');
  const [index, setIndex] = useState(0);
  useEffect(() => {
    setIndex(0);
  }, [urlKey]);
  const url = urls[index] ?? null;
  if (url === null) {
    return props.fallback === 'hide' ? null : (
      <span className={`${props.className}-missing`}>图标缺失</span>
    );
  }
  return (
    <img
      className={props.className}
      src={url}
      alt=""
      width={props.size}
      height={props.size}
      onError={() => setIndex((i) => i + 1)}
    />
  );
}
