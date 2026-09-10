import { useEffect, useMemo, useState, type ReactNode } from 'react';

import type { CatalogAssetRefDto } from '@coc-helper/contracts';

import { overviewAssetUrl } from '../asset-url';

export function AssetImage(props: {
  readonly catalogVersion: string | null;
  readonly candidates: readonly (CatalogAssetRefDto | null)[];
  readonly size: number;
  readonly className: string;
  /** 候选耗尽时的最终 fallback（#39 要求不得静默消失，由调用方按分类提供）。 */
  readonly fallbackNode: ReactNode;
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
    return <>{props.fallbackNode}</>;
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
