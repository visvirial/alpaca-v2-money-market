interface UpgradableContract {
  implementation: string;
  proxy: string;
}

interface AccountManager extends UpgradableContract {}

export interface Config {
  moneyMarket: MoneyMarket;
  miniFL: MiniFL;
  rewarders: Rewarder[];
  proxyAdmin: string;
  timelock: string;
  opMultiSig: string;
}

export interface MoneyMarket {
  moneyMarketDiamond: string;
  facets: {
    adminFacet: string;
    borrowFacet: string;
    collateralFacet: string;
    diamondCutFacet: string;
    diamondLoupeFacet: string;
    flashloanFacet: string;
    lendFacet: string;
    liquidationFacet: string;
    nonCollatBorrowFacet: string;
    ownershipFacet: string;
    viewFacet: string;
  };
  markets: Market[];
  accountManager: AccountManager;
}

export interface MiniFL {
  pools: MiniFLPool[];
}

export interface Market {
  name: string;
  tier: string;
  token: string;
  ibToken: string;
  debtToken: string;
  interestModel: string;
}

export interface MiniFLPool {
  id: number;
  name: string;
  stakingToken: string;
  rewarders: Rewarder[];
}

export interface Rewarder {
  name: string;
  address: string;
  rewardToken: string;
}

export type AssetTier = 0 | 1 | 2 | 3;
type AssetTierString = "UNLISTED" | "ISOLATE" | "CROSS" | "COLLATERAL";
export const reverseAssetTier: Record<AssetTier, AssetTierString> = {
  0: "UNLISTED",
  1: "ISOLATE",
  2: "CROSS",
  3: "COLLATERAL",
};

export interface TimelockTransaction {
  info: string;
  chainId: number;
  queuedAt: string;
  executedAt: string;
  executionTransaction: string;
  target: string;
  value: string;
  signature: string;
  paramTypes: Array<string>;
  params: Array<any>;
  eta: string;
}
