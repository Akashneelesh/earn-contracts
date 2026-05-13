// Copy to ./config.js and fill in. This file is gitignored.
//
// Public addresses are safe; the Starknet RPC URL may contain an API key
// so don't commit your real config.js.

export const CONFIG = {
  // Ethereum Sepolia
  TRIGGER_ADDRESS:  "0xEf1CCEc22D65E8fB96653fdd009Bf308D256DEa9",
  ETH_CHAIN_ID:     11155111,
  ETH_CHAIN_HEX:    "0xaa36a7",
  ETH_CHAIN_NAME:   "Sepolia",

  // Starknet Sepolia
  COUNTER_ADDRESS:  "0x01df31db648414d6278f9b12d8f228cc5282b397c4ec86d1947abf80717e8f39",
  STARKNET_RPC:     "https://api.cartridge.gg/x/starknet/sepolia",

  // LayerZero
  DST_EID_STARKNET: 40500,
  DST_EID_ETHEREUM: 40161,

  // Sepolia RPC used by the burner wallet (read state + send txs)
  SEPOLIA_RPC:      "https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY",
  ETH_PUBLIC_RPC:   "https://ethereum-sepolia-rpc.publicnode.com",

  // Burner mode: page signs with this key directly, no MetaMask popup.
  // Leave as "" to fall back to MetaMask mode.
  // ⚠ ONLY use a throwaway testnet key — never a key with real funds.
  BURNER_PRIVATE_KEY: "",

  // Counter v3 (ABA) — set after running scripts/10..12.
  COUNTER_V3_ETH:    "",
  COUNTER_V3_SN:     "",

  // ---- TIER 2 PRIVACY MODE (phase 1) ------------------------------------
  // When PRIVACY toggle is ON, SN-originated presses are routed through an
  // unlinkable Tier-2 account funded by Alice via the AVNU paymaster +
  // starknet-privacy-sdk pool. Copy values from
  //   tier2_wallet/demo/config.ts and tier2_wallet/sepolia-deployments.json
  // The privacy SDK needs RPC spec 0.10, so this is a separate RPC from the
  // STARKNET_RPC above (which is pinned to 0.8.1 for starknet.js v7 compat).
  TIER2_STARKNET_RPC:           "",
  TIER2_STARKNET_CHAIN_ID:      "0x534e5f5345504f4c4941",
  TIER2_NETWORK:                "prod",
  TIER2_POOL_ADDRESS:           "",
  TIER2_POOL_FEE_TOKEN:         "",
  TIER2_DISCOVERY_URL:          "",
  TIER2_PROVING_URL:            "",
  TIER2_PAYMASTER_URL:          "https://sepolia.paymaster.avnu.fi",
  TIER2_PAYMASTER_API_KEY:      "",
  TIER2_FACTORY_ADDRESS:        "",
  TIER2_HELPER_ADDRESS:         "",
  TIER2_INVOKE_HELPER_ADDRESS:  "",
  // Alice = pool sponsor. SHIPS TO BROWSER. Throwaway only.
  TIER2_ALICE_ADDRESS:          "",
  TIER2_ALICE_PRIVATE_KEY:      "",
  TIER2_ALICE_VIEWING_KEY:      "",
};
