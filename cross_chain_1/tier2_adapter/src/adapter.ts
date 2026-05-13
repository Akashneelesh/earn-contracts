/**
 * Tier-2 adapter for cross_chain_1 frontend.
 *
 * Wraps tier2_wallet's sponsored-deploy + sponsored-execute primitives behind a
 * narrow surface the frontend can call. The frontend imports the bundled output
 * (../frontend/tier2-adapter.bundle.js) and instantiates Tier2Adapter once.
 *
 * Privacy model in phase 1:
 *   - MetaMask -> session key -> deterministic Tier-2 Starknet account.
 *   - Account deploy and every execute is sponsored privately by Alice via
 *     the AVNU paymaster + starknet-privacy-sdk pool. MM never appears on chain.
 *   - The Tier-2 account itself must hold STRK to pay LayerZero fees on
 *     trigger_increment (the OApp does transferFrom(caller, contract, fee) and
 *     caller != contract here, so the carve-out for self-pay does not apply).
 *     For POC simplicity, the user funds the Tier-2 account manually with STRK
 *     after first deploy. That funding tx is the one correlation point - phase 2
 *     replaces it with a privacy-pool-native funding path.
 */

import {
  ANY_CALLER,
  BrowserMmSigner,
  computeAccountAddress,
  deriveSessionKey,
  PaymasterClient,
  privateSponsoredDeployTier2Account,
  privateSponsoredExecuteOnTier2Account,
  type SessionKey,
} from "tier2-wallet";
import {
  Account,
  RpcProvider,
  constants as starknetConstants,
  hash,
} from "starknet";
import {
  IndexerDiscoveryProvider,
  ProvingServiceProofProvider,
  createPrivateTransfers,
} from "@starkware-libs/starknet-privacy-sdk";

type Hex = `0x${string}`;
type Log = (line: string) => void;

export interface Tier2AdapterConfig {
  starknetRpcUrl: string;
  /** Short-string-encoded Starknet chain id (e.g. "0x534e5f5345504f4c4941"). */
  starknetChainId: string;
  /** "prod" matches the on-chain Primer class hash. */
  network: "prod" | "test";

  poolAddress: Hex;
  poolFeeToken: Hex;
  discoveryUrl: string;
  provingUrl: string;

  paymasterUrl: string;
  paymasterApiKey: string;

  factoryAddress: Hex;
  /** EarnDeployHelper - calls factory.deploy_account. */
  helperAddress: Hex;
  /** EarnInvokeHelper - calls target.execute_from_outside_v2. */
  invokeHelperAddress: Hex;

  /**
   * Alice = sponsor account that owns notes in the privacy pool. The Tier-2
   * user never sees this key; it is bundled into the demo for POC purposes only.
   */
  alice: { address: Hex; privateKey: Hex; viewingKey: Hex };
}

export interface DeployResult {
  tier2Address: string;
  txHash: string;
  feePaidByAlice: bigint;
}

export interface ExecuteResult {
  txHash: string;
  feePaidByAlice: bigint;
}

export class Tier2Adapter {
  private signer: BrowserMmSigner | null = null;
  private session: SessionKey | null = null;
  private tier2Address: bigint | null = null;

  constructor(public readonly cfg: Tier2AdapterConfig) {}

  /** Connect MetaMask (no signing yet). */
  async connectMm(): Promise<{ mmAddress: string }> {
    const eth = (globalThis as { ethereum?: unknown }).ethereum;
    if (!eth) throw new Error("MetaMask not detected. Install it and refresh.");
    this.signer = new BrowserMmSigner(eth);
    return { mmAddress: await this.signer.address() };
  }

  /** Ask MM to personal_sign the fixed bootstrap message and derive the session key. */
  async deriveSession(): Promise<{ sessionEthAddress: string }> {
    if (!this.signer) throw new Error("Call connectMm() first");
    this.session = await deriveSessionKey(this.signer);
    return { sessionEthAddress: this.session.ethAddress };
  }

  /** Predict the Starknet account address (pure client-side, no RPC). */
  computeTier2Address(): string {
    if (!this.session) throw new Error("Call deriveSession() first");
    const addr = computeAccountAddress({
      sessionEthAddress: this.session.ethAddress,
      factoryAddress: this.cfg.factoryAddress,
      network: this.cfg.network,
    });
    this.tier2Address = addr;
    return "0x" + addr.toString(16).padStart(64, "0");
  }

  /** Has the Tier-2 account already been deployed? */
  async isDeployed(): Promise<boolean> {
    if (this.tier2Address == null) this.computeTier2Address();
    const provider = new RpcProvider({ nodeUrl: this.cfg.starknetRpcUrl });
    const addrHex =
      "0x" + this.tier2Address!.toString(16).padStart(64, "0");
    try {
      const classHash = await provider.getClassHashAt(addrHex);
      return classHash !== "0x0" && classHash !== undefined && classHash !== null;
    } catch {
      return false;
    }
  }

  /** Sponsor-deploy the Tier-2 account via Alice + paymaster + privacy pool. */
  async deploy(log?: Log): Promise<DeployResult> {
    if (!this.session) throw new Error("Call deriveSession() first");
    const { transfers, alice, provider, paymaster } = this.buildSdkDeps();
    const result = await privateSponsoredDeployTier2Account(
      {
        starknetChainId: this.cfg.starknetChainId,
        poolAddress: this.cfg.poolAddress,
        poolFeeToken: this.cfg.poolFeeToken,
        helperAddress: this.cfg.helperAddress,
        factoryAddress: this.cfg.factoryAddress,
        network: this.cfg.network,
        paymasterApiKey: this.cfg.paymasterApiKey,
        paymasterUrl: this.cfg.paymasterUrl,
      },
      {
        alice,
        provider,
        transfers,
        paymaster,
        session: this.session,
        log,
      },
    );
    this.tier2Address = result.accountAddress;
    return {
      tier2Address: result.accountAddressHex,
      txHash: result.transactionHash,
      feePaidByAlice: result.feePaidByAlice,
    };
  }

  /**
   * Call Counter.trigger_increment via the Tier-2 account.
   *
   * Multi-call shape: [STRK.approve(counter, fee*1.5), counter.trigger_increment(dst, by, gas)].
   * The approve covers the LZ fee the OApp will transferFrom on the next line.
   * Alice pays the Starknet gas via the paymaster.
   */
  async triggerIncrementViaTier2(opts: {
    counterAddress: Hex;
    dstEid: number;
    by: number;
    gasLimit: bigint;
    /** Fee returned by counter.quote_trigger_increment. Already in raw u256. */
    lzNativeFee: bigint;
    /** STRK ERC-20 token address (same as poolFeeToken on Sepolia). */
    strkAddress: Hex;
    log?: Log;
  }): Promise<ExecuteResult> {
    if (!this.session) throw new Error("Call deriveSession() first");
    if (this.tier2Address == null) this.computeTier2Address();
    const accountAddrHex =
      "0x" + this.tier2Address!.toString(16).padStart(64, "0");

    // Approve 1.5x the quoted fee so small drift between quote and broadcast
    // doesn't cause a revert.
    const approval = (opts.lzNativeFee * 3n) / 2n;
    const MASK_128 = (1n << 128n) - 1n;

    const calls = [
      {
        to: BigInt(opts.strkAddress),
        selector: BigInt(hash.getSelectorFromName("approve")),
        calldata: [
          BigInt(opts.counterAddress),
          approval & MASK_128,
          approval >> 128n,
        ],
      },
      {
        to: BigInt(opts.counterAddress),
        selector: BigInt(hash.getSelectorFromName("trigger_increment")),
        calldata: [BigInt(opts.dstEid), BigInt(opts.by), opts.gasLimit],
      },
    ];

    const nonce =
      BigInt(Date.now()) * 1000n + BigInt(Math.floor(Math.random() * 1000));

    const { transfers, alice, provider, paymaster } = this.buildSdkDeps();
    const result = await privateSponsoredExecuteOnTier2Account(
      {
        starknetChainId: this.cfg.starknetChainId,
        poolAddress: this.cfg.poolAddress,
        poolFeeToken: this.cfg.poolFeeToken,
        invokeHelperAddress: this.cfg.invokeHelperAddress,
        paymasterApiKey: this.cfg.paymasterApiKey,
        paymasterUrl: this.cfg.paymasterUrl,
      },
      {
        alice,
        provider,
        transfers,
        paymaster,
        session: this.session,
        accountAddress: accountAddrHex,
        calls,
        nonce,
        log: opts.log,
      },
    );
    return {
      txHash: result.transactionHash,
      feePaidByAlice: result.feePaidByAlice,
    };
  }

  /** STRK balance of the Tier-2 account (so the UI can warn if it's empty). */
  async getTier2StrkBalance(strkAddress: Hex): Promise<bigint> {
    if (this.tier2Address == null) this.computeTier2Address();
    const provider = new RpcProvider({ nodeUrl: this.cfg.starknetRpcUrl });
    const addrHex =
      "0x" + this.tier2Address!.toString(16).padStart(64, "0");
    const out = await provider.callContract({
      contractAddress: strkAddress,
      entrypoint: "balanceOf",
      calldata: [addrHex],
    });
    // ERC-20 balanceOf returns u256 = [low, high].
    const low = BigInt(out[0]);
    const high = BigInt(out[1]);
    return (high << 128n) | low;
  }

  // ---- internal -----------------------------------------------------------

  private buildSdkDeps() {
    const provider = new RpcProvider({ nodeUrl: this.cfg.starknetRpcUrl });
    const alice = new Account({
      provider,
      address: this.cfg.alice.address,
      signer: this.cfg.alice.privateKey,
      cairoVersion: "1",
    });
    const discovery = new IndexerDiscoveryProvider(
      this.cfg.discoveryUrl,
      this.cfg.poolAddress,
    );
    const provingProvider = new ProvingServiceProofProvider(
      this.cfg.provingUrl,
      this.cfg.starknetChainId as unknown as starknetConstants.StarknetChainId,
    );
    const viewingKey = BigInt(this.cfg.alice.viewingKey);
    // Cast: privacy SDK and adapter pull starknet from different node_modules
    // trees so TS sees the Account types as nominally distinct even though
    // they're the same version. Runtime behaviour is identical.
    const transfers = createPrivateTransfers({
      account: alice as unknown as Parameters<typeof createPrivateTransfers>[0]["account"],
      viewingKeyProvider: { getViewingKey: async () => viewingKey },
      provingProvider,
      discoveryProvider: discovery,
      poolContractAddress: this.cfg.poolAddress,
    });
    const paymaster = new PaymasterClient(
      this.cfg.paymasterUrl,
      this.cfg.paymasterApiKey,
    );
    return { transfers, alice, provider, paymaster };
  }
}

// Re-export ANY_CALLER for symmetry / debugging from the browser console.
export { ANY_CALLER };
