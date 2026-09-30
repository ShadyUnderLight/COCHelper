import type { OfficialClanWarBundleApi } from '../use-official-clan-war-bundle';
import type { OfficialVillageApi } from '../use-official-village';
import { CapitalRaidCard } from './CapitalRaidCard';
import { ClanCard } from './ClanCard';
import { ClanWarCard } from './ClanWarCard';
import { WarLogCard } from './WarLogCard';

export type ClanDetailProps = {
  readonly official?: OfficialVillageApi;
  readonly officialWar?: OfficialClanWarBundleApi;
};

export function ClanDetail({ official, officialWar }: ClanDetailProps) {
  const clanTag = official?.clan.clanTag;
  return (
    <section className="clan-detail-panel" aria-label="部落详情">
      <header className="detail-header">
        <p className="section-eyebrow">CLAN / WAR INTELLIGENCE</p>
        <div className="detail-title-row">
          <h2>部落详情</h2>
          <p className="muted">当前村庄所属部落、部落对战、对战日志与突袭周末</p>
        </div>
        {clanTag !== null && clanTag !== undefined ? (
          <span className="official-source">{clanTag}</span>
        ) : null}
      </header>

      {official === undefined ? (
        <section className="detail-section">
          <p className="muted">选择村庄并启用官方数据接口后，可查看部落详情。</p>
        </section>
      ) : (
        <div className="clan-detail-cards">
          <ClanCard
            view={official.clan}
            refreshing={official.clanRefreshing}
            onRefresh={() => void official.refreshClan()}
          />
          {officialWar !== undefined ? (
            <>
              <ClanWarCard api={officialWar.clanWar} />
              <WarLogCard api={officialWar.warLog} />
              <CapitalRaidCard api={officialWar.capitalRaid} />
            </>
          ) : null}
        </div>
      )}
    </section>
  );
}
