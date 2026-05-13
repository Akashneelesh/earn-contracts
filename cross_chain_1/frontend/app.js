// ---------------------------------------------------------------------------
// Transmission Console — bidirectional. Both buttons sign locally with burner
// keys from config.js. No MetaMask, no Argent.
// ---------------------------------------------------------------------------

import { ethers } from "https://esm.sh/ethers@6.13.4";
import { Account, RpcProvider } from "https://esm.sh/starknet@7.5.0";
import { keccak_256 } from "https://esm.sh/@noble/hashes@1.5.0/sha3";
import { CONFIG } from "./config.js";
import { Tier2Adapter } from "./tier2-adapter.bundle.js";

// --- Tier 2 privacy mode -----------------------------------------------------
const PRIVACY_STORAGE_KEY = "crosschain.privacy-mode.v1";

// --- EVM ABI -----------------------------------------------------------------
const TRIGGER_ABI = [
  "function defaultOptions() pure returns (bytes)",
  "function quoteTriggerIncrement(uint32 dstEid, uint64 by, bytes options) view returns ((uint256 nativeFee, uint256 lzTokenFee))",
  "function triggerIncrement(uint32 dstEid, uint64 by, bytes options) payable returns ((bytes32 guid, uint64 nonce, (uint256 nativeFee, uint256 lzTokenFee) fee))",
  "function count() view returns (uint64)",
  "function lastIncrementBy() view returns (uint64)",
  "function lastSrcEid() view returns (uint32)",
  "event IncrementReceived(uint32 indexed srcEid, bytes32 guid, uint64 by, uint64 newCount)",
];

// --- Counter V3 ABI (ABA round-trip) -----------------------------------------
const COUNTER_V3_ABI = [
  "function defaultAbaOptions() view returns (bytes)",
  "function quoteAbaIncrement(uint32 dstEid, uint64 bySn, uint64 byEth, bytes options) view returns ((uint256 nativeFee, uint256 lzTokenFee))",
  "function triggerAbaIncrement(uint32 dstEid, uint64 bySn, uint64 byEth, bytes options) payable",
  "function count() view returns (uint64)",
];

// --- Starknet selector helper ------------------------------------------------
function snKeccak(name) {
  const bytes = keccak_256(new TextEncoder().encode(name));
  let hex = "";
  for (const b of bytes) hex += b.toString(16).padStart(2, "0");
  const big = BigInt("0x" + hex) & ((1n << 250n) - 1n);
  return "0x" + big.toString(16);
}

async function starknetCall(rpc, contractAddress, selector, calldata = []) {
  const res = await fetch(rpc, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      jsonrpc: "2.0", id: 1,
      method: "starknet_call",
      params: [
        { contract_address: contractAddress, entry_point_selector: selector, calldata },
        "latest",
      ],
    }),
  });
  const j = await res.json();
  if (j.error) throw new Error(j.error.message || JSON.stringify(j.error));
  return j.result;
}

// --- DOM helpers -------------------------------------------------------------
const $ = (s) => document.querySelector(s);
const shortAddr = (a) => (a ? a.slice(0, 6) + "…" + a.slice(-4) : "—");
const shortFelt = (a) => (a ? a.slice(0, 6) + "…" + a.slice(-6) : "—");

function toast(msg, kind = "") {
  const el = document.createElement("div");
  el.className = "toast " + (kind === "ok" ? "is-ok" : kind === "err" ? "is-err" : "");
  el.textContent = msg;
  $("#toasts").appendChild(el);
  setTimeout(() => el.remove(), 6500);
}

// --- Digit ticker (per-counter) ----------------------------------------------
const DIGIT_TARGETS = {
  sn: "#sn-digits",
  eth: "#eth-digits",
  "aba-sn": "#aba-sn-digits",
  "aba-eth": "#aba-eth-digits",
};
const lastRendered = { sn: null, eth: null, "aba-sn": null, "aba-eth": null };
function renderDigits(side, n) {
  const root = $(DIGIT_TARGETS[side]);
  if (!root) return;
  const padded = String(n).padStart(8, "0");
  const prev = lastRendered[side] == null ? null : String(lastRendered[side]).padStart(8, "0");
  root.innerHTML = "";
  for (let i = 0; i < padded.length; i++) {
    const d = document.createElement("span");
    d.className = "digit";
    d.textContent = padded[i];
    if (prev && prev[i] !== padded[i]) {
      d.classList.add("tick");
      setTimeout(() => d.classList.remove("tick"), 900);
    }
    root.appendChild(d);
  }
  lastRendered[side] = n;
}

// --- State -------------------------------------------------------------------
const SELECTORS = {
  count: null, last_increment_by: null, last_src_eid: null,
  quote_trigger_increment: null, trigger_increment: null,
};
const state = {
  ethProvider: null, ethWallet: null, ethTrigger: null,
  snProvider: null, snAccount: null,
  snCount: 0, ethCount: 0,
  snLastBy: null, snLastEid: null,
  ethLastBy: null, ethLastEid: null,
  amounts: { eth: 5, sn: 5 },
  txs: [],            // log entries, newest first
  logExpanded: false, // collapsed shows first 12; expanded shows all
  // --- Tier 2 privacy mode -------------------------------------------------
  privacy: false,        // toggle state
  tier2: null,           // Tier2Adapter instance (lazily constructed)
  tier2Stage: "setup",   // setup | mm-connected | session-derived | deployed | ready
  tier2MmAddr: null,
  tier2SessionAddr: null,
  tier2AccountAddr: null,
  tier2StrkBal: 0n,
};

// --- Log persistence --------------------------------------------------------
// Survives reloads via localStorage. Bump the version suffix if the entry
// shape ever changes in an incompatible way.
const LOG_STORAGE_KEY = "crosschain.transmission-log.v1";
const LOG_COLLAPSED_LIMIT = 12;

function loadLog() {
  try {
    const raw = localStorage.getItem(LOG_STORAGE_KEY);
    if (!raw) return [];
    const parsed = JSON.parse(raw);
    return Array.isArray(parsed) ? parsed : [];
  } catch { return []; }
}

function persistLog() {
  try { localStorage.setItem(LOG_STORAGE_KEY, JSON.stringify(state.txs)); }
  catch { /* quota or disabled — silent */ }
}

// Known historical SN→ETH source tx hashes that LZ scan can still resolve.
// The wallet-endpoint only returns ETH-initiated messages, so we probe these
// individually to backfill the Starknet side. Drop entries the API forgets.
const KNOWN_SN_TXS = [
  "0x1152e34106f1f2fe37c5abb2aaf758e8b4d6c28b8522711d5746b747d775273", // counter +5 (Node test)
  "0x04a36488ad6d474c17d8770f30f4e9c82f96790df462bb06f3985dcbef04bd18", // string "hello from starknet"
  "0x004b151578aa8f29882c3db1e4b5ed90c7620ff04b3259e941cf66423633edb0", // counter +7
];

// Status values that are not yet terminal — boot reconciliation re-queries
// these against LZ scan in case delivery completed while the page was closed.
const NON_TERMINAL_STATUSES = new Set(["pending", "eth-ok", "sn-ok", "aba-half"]);

async function fetchLzMessage(txHash) {
  try {
    const r = await fetch(`https://scan-testnet.layerzero-api.com/v1/messages/tx/${txHash}`);
    if (!r.ok) return null;
    const j = await r.json();
    const m = (j.data || [])[0];
    if (!m || !m.pathway?.srcEid) return null;
    return m;
  } catch { return null; }
}

// For each non-terminal entry with a known source tx, query LZ scan for the
// real on-chain state and update the entry in-place. Two-leg lookup for ABA:
// (1) original eth->sn leg; if delivered, walk to (2) the auto-emitted sn->eth
// return leg via the SN delivery tx hash. Returns the count of entries changed.
async function reconcileLogFromLzScan() {
  const pending = state.txs.filter(
    (t) => NON_TERMINAL_STATUSES.has(t.status) && (t.ethTx || t.snTx),
  );
  if (pending.length === 0) return 0;

  let changed = 0;
  await Promise.all(pending.map(async (entry) => {
    const sourceTx = entry.side === "sn->eth" ? entry.snTx : entry.ethTx;
    if (!sourceTx) return;
    const leg1 = await fetchLzMessage(sourceTx);
    if (!leg1) return;

    const leg1Done = leg1.destination?.status === "SUCCEEDED";
    const leg1Failed = leg1.destination?.status === "SIMULATION_REVERTED"
                     || leg1.status?.name === "FAILED";

    if (entry.side === "aba") {
      // Step 1: the eth->sn leg must land before we know anything.
      if (leg1Failed) { entry.status = "failed"; changed++; return; }
      if (!leg1Done) return; // still in flight; leave status as-is

      const snDeliveryTx = leg1.destination?.tx?.txHash;
      if (snDeliveryTx && entry.snTx !== snDeliveryTx) entry.snTx = snDeliveryTx;

      // Promote to aba-half if we hadn't already.
      if (entry.status !== "aba-half") {
        entry.status = "aba-half";
        changed++;
      }

      // Step 2: the SN delivery tx is the source of the auto-emitted return leg.
      if (!snDeliveryTx) return;
      const leg2 = await fetchLzMessage(snDeliveryTx);
      if (!leg2) return;
      if (leg2.destination?.status === "SUCCEEDED") {
        entry.status = "delivered";
        const finishedAtMs = (leg2.destination.tx?.blockTimestamp || 0) * 1000;
        if (finishedAtMs && entry.startedAt) {
          entry.latencySec = Math.round((finishedAtMs - entry.startedAt) / 1000);
        }
        changed++;
      } else if (leg2.destination?.status === "SIMULATION_REVERTED"
              || leg2.status?.name === "FAILED") {
        entry.status = "failed";
        changed++;
      }
      return;
    }

    // Single-hop entries (eth->sn or sn->eth).
    if (leg1Done) {
      entry.status = "delivered";
      const finishedAtMs = (leg1.destination.tx?.blockTimestamp || 0) * 1000;
      if (finishedAtMs && entry.startedAt) {
        entry.latencySec = Math.round((finishedAtMs - entry.startedAt) / 1000);
      }
      changed++;
    } else if (leg1Failed) {
      entry.status = "failed";
      changed++;
    }
  }));

  if (changed > 0) renderLog();
  return changed;
}

// Decode the payload of a LZ message back to (by) or (bySn, byEth).
// Single-hop format: 32 bytes, last 8 bytes = uint64.
// ABA format:       17 bytes, tag 0x01 + bySn (8B BE) + byEth (8B BE).
function decodeLzPayload(payloadHex) {
  if (!payloadHex || !payloadHex.startsWith("0x")) return {};
  const hex = payloadHex.slice(2);
  if (hex.length === 64) {       // 32 bytes — plain uint64
    return { by: Number(BigInt("0x" + hex.slice(-16))) };
  }
  if (hex.length === 34 && hex.startsWith("01")) { // 17 bytes — ABA
    return {
      bySn:  Number(BigInt("0x" + hex.slice(2, 18))),
      byEth: Number(BigInt("0x" + hex.slice(18, 34))),
    };
  }
  return {}; // unknown shape (e.g. string demo) — leave amount blank
}

function lzMessageToLogEntry(msg) {
  const srcEid = msg.pathway?.srcEid;
  const dstEid = msg.pathway?.dstEid;
  const destStatus = msg.destination?.status;
  const destName = msg.status?.name;
  const status =
    destStatus === "SUCCEEDED" ? "delivered" :
    destStatus === "SIMULATION_REVERTED" || destName === "FAILED" ? "failed" :
    destName === "INFLIGHT" ? "pending" :
    "pending";

  const startedAt = (msg.source?.tx?.blockTimestamp || 0) * 1000;
  const payload = msg.source?.tx?.payload || "";
  const amounts = decodeLzPayload(payload);
  const isAba = amounts.bySn != null;

  const srcTx  = msg.source?.tx?.txHash || null;
  const destTx = msg.destination?.tx?.txHash || null;
  // Side mapping: 40161 = Sepolia, 40500 = Starknet Sepolia.
  let side;
  if (srcEid === 40161 && dstEid === 40500) side = isAba ? "aba" : "eth->sn";
  else if (srcEid === 40500 && dstEid === 40161) side = "sn->eth";
  else side = "eth->sn"; // fallback

  return {
    side,
    startedAt,
    by: amounts.by ?? null,
    bySn: amounts.bySn ?? null,
    byEth: amounts.byEth ?? null,
    ethTx: srcEid === 40161 ? srcTx : destTx,
    snTx:  srcEid === 40500 ? srcTx : destTx,
    status,
    imported: true,
  };
}

async function importHistoryFromLzScan() {
  const btn = $("#log-import-btn");
  if (btn.disabled) return;
  btn.disabled = true;
  const orig = btn.textContent;
  btn.textContent = "IMPORTING…";
  try {
    if (!state.ethWallet) throw new Error("ETH burner not ready");
    const burner = (await state.ethWallet.getAddress()).toLowerCase();

    const walletUrl = `https://scan-testnet.layerzero-api.com/v1/messages/wallet/${burner}?limit=100`;
    const walletRes = await fetch(walletUrl);
    if (!walletRes.ok) throw new Error(`LZ scan ${walletRes.status}`);
    const walletJson = await walletRes.json();
    const fromWallet = (walletJson.data || []).map(lzMessageToLogEntry);

    const snProbes = await Promise.all(
      KNOWN_SN_TXS.map(async (h) => {
        try {
          const r = await fetch(`https://scan-testnet.layerzero-api.com/v1/messages/tx/${h}`);
          if (!r.ok) return null;
          const j = await r.json();
          const m = (j.data || [])[0];
          if (!m || !m.pathway?.srcEid) return null;
          const entry = lzMessageToLogEntry(m);
          if (entry.side === "sn->eth" && !entry.snTx) entry.snTx = h;
          return entry;
        } catch { return null; }
      }),
    );
    const fromSn = snProbes.filter(Boolean);

    const incoming = [...fromWallet, ...fromSn];
    const seen = new Set(
      state.txs.map((t) => (t.ethTx || t.snTx || "").toLowerCase()).filter(Boolean),
    );
    const fresh = incoming.filter((t) => {
      const k = (t.ethTx || t.snTx || "").toLowerCase();
      if (!k || seen.has(k)) return false;
      seen.add(k);
      return true;
    });

    state.txs = [...state.txs, ...fresh].sort((a, b) => (b.startedAt || 0) - (a.startedAt || 0));
    renderLog();
    toast(`imported ${fresh.length} historical entr${fresh.length === 1 ? "y" : "ies"}`, fresh.length ? "ok" : "");
  } catch (e) {
    console.error("import history:", e);
    toast(`import failed: ${e.message || e}`, "err");
  } finally {
    btn.disabled = false;
    btn.textContent = orig;
  }
}

// --- click-to-copy helper ----------------------------------------------------
async function copyToClipboard(text) {
  try {
    await navigator.clipboard.writeText(text);
  } catch {
    // fallback for non-secure / older browsers
    const ta = document.createElement("textarea");
    ta.value = text; ta.style.position = "fixed"; ta.style.opacity = "0";
    document.body.appendChild(ta); ta.select();
    try { document.execCommand("copy"); } finally { document.body.removeChild(ta); }
  }
}

// Build a small "copy" button bound to `value`. Returns the <button> element.
function copyButton(value) {
  const btn = document.createElement("button");
  btn.type = "button";
  btn.className = "copy-btn";
  btn.textContent = "copy";
  btn.title = `Copy ${value}`;
  btn.addEventListener("click", async (e) => {
    e.stopPropagation();
    await copyToClipboard(value);
    btn.classList.remove("is-copied"); void btn.offsetWidth;
    btn.classList.add("is-copied");
    btn.textContent = "copied";
    setTimeout(() => {
      btn.classList.remove("is-copied");
      btn.textContent = "copy";
    }, 1100);
  });
  return btn;
}

function makeCopyable(el, fullValue) {
  if (!el) return;
  el.classList.add("copy");
  el.dataset.fullAddress = fullValue;
  el.title = `${fullValue} — click to copy`;
  el.setAttribute("role", "button");
  el.setAttribute("tabindex", "0");

  const fire = async () => {
    const v = el.dataset.fullAddress;
    try {
      await navigator.clipboard.writeText(v);
    } catch {
      // fallback: select + execCommand
      const r = document.createRange(); r.selectNodeContents(el);
      const sel = window.getSelection(); sel.removeAllRanges(); sel.addRange(r);
      document.execCommand?.("copy");
      sel.removeAllRanges();
    }
    el.classList.remove("is-copied"); void el.offsetWidth; el.classList.add("is-copied");
    setTimeout(() => el.classList.remove("is-copied"), 900);
  };

  if (!el.dataset.copyWired) {
    el.dataset.copyWired = "1";
    el.addEventListener("click", fire);
    el.addEventListener("keydown", (e) => {
      if (e.key === "Enter" || e.key === " ") { e.preventDefault(); fire(); }
    });
  }
}

// --- Boot --------------------------------------------------------------------
async function boot() {
  // addresses (full + copyable in footer)
  $("#addr-trigger").textContent = CONFIG.TRIGGER_ADDRESS;
  $("#addr-counter").textContent = CONFIG.COUNTER_ADDRESS;
  makeCopyable($("#addr-trigger"), CONFIG.TRIGGER_ADDRESS);
  makeCopyable($("#addr-counter"), CONFIG.COUNTER_ADDRESS);

  // Tier-2 / privacy toggle
  setupTier2();

  // selectors
  SELECTORS.count                   = snKeccak("count");
  SELECTORS.last_increment_by       = snKeccak("last_increment_by");
  SELECTORS.last_src_eid            = snKeccak("last_src_eid");
  SELECTORS.quote_trigger_increment = snKeccak("quote_trigger_increment");
  SELECTORS.trigger_increment       = snKeccak("trigger_increment");

  // amount chips — per side
  document.querySelectorAll(".amount-row").forEach((row) => {
    const side = row.dataset.side; // "eth" | "sn"
    row.querySelectorAll(".amount-chip").forEach((c) => {
      c.addEventListener("click", () => {
        row.querySelectorAll(".amount-chip").forEach((x) => x.classList.remove("is-active"));
        c.classList.add("is-active");
        state.amounts[side] = Number(c.dataset.amount);
        const subEl = $(`#${side}-bb-sub`);
        if (subEl && !subEl.dataset.locked) {
          subEl.textContent = side === "eth"
            ? `+${state.amounts.eth} on starknet`
            : `+${state.amounts.sn} on ethereum`;
        }
      });
    });
  });

  // wallets
  await Promise.all([setupEth(), setupStarknet()]);

  // If privacy was on from a prior session, swap the SN-account label now
  // that setupStarknet has populated the element with the burner default.
  if (state.privacy) renderSnAccountLabel();

  // rehydrate transmission log from prior sessions
  state.txs = loadLog();
  $("#log-expand-btn").addEventListener("click", () => {
    state.logExpanded = !state.logExpanded;
    renderLog();
  });
  $("#log-clear-btn").addEventListener("click", () => {
    if (state.txs.length === 0) return;
    if (!confirm(`Clear all ${state.txs.length} log entries? This cannot be undone.`)) return;
    state.txs = [];
    state.logExpanded = false;
    persistLog();
    renderLog();
  });
  $("#log-import-btn").addEventListener("click", importHistoryFromLzScan);
  renderLog();

  // Reconcile non-terminal entries against LZ scan in case delivery completed
  // while the page was closed. Fires-and-forgets so it never blocks boot.
  reconcileLogFromLzScan().catch((e) => console.error("reconcile:", e));

  // buttons
  $("#eth-press-btn").addEventListener("click", onPressEth);
  $("#sn-press-btn").addEventListener("click", onPressSn);

  // ABA button — enabled only after both wallets are ready
  const abaBtn = document.getElementById("aba-press-btn");
  abaBtn.addEventListener("click", pressAba);
  if (state.ethWallet && state.snAccount) {
    abaBtn.disabled = false;
    document.getElementById("aba-bb-sub").textContent = "ready";
    setAbaStatus("idle");
  }

  // counters
  await Promise.all([refreshStarknetCount(), refreshEthCount()]);
  renderDigits("sn", state.snCount);
  renderDigits("eth", state.ethCount);
  setInterval(refreshStarknetCount, 5000);
  setInterval(refreshEthCount, 5000);

  // v3 ABA counters
  await refreshAbaCounts();
  setInterval(refreshAbaCounts, 5000);

  // overall status
  const ok = state.ethTrigger && state.snAccount;
  const statusEl = $("#net-status");
  statusEl.classList.add(ok ? "is-ok" : "is-err");
  statusEl.querySelector(".status-text").textContent = ok ? "BURNERS · ARMED" : "BURNER · ERROR";
}

// --- ETH side setup ----------------------------------------------------------
async function setupEth() {
  try {
    if (!CONFIG.BURNER_PRIVATE_KEY) throw new Error("BURNER_PRIVATE_KEY missing");
    state.ethProvider = new ethers.JsonRpcProvider(CONFIG.SEPOLIA_RPC || CONFIG.ETH_PUBLIC_RPC);
    state.ethWallet = new ethers.Wallet(CONFIG.BURNER_PRIVATE_KEY, state.ethProvider);
    state.ethTrigger = new ethers.Contract(CONFIG.TRIGGER_ADDRESS, TRIGGER_ABI, state.ethWallet);
    const addr = await state.ethWallet.getAddress();
    const acctEl = $("#eth-account");
    acctEl.innerHTML = `<span class="eth-acct-short">${shortAddr(addr)}</span> <span class="burner-tag">burner</span>`;
    makeCopyable(acctEl.querySelector(".eth-acct-short"), addr);
    acctEl.appendChild(copyButton(addr));
    $("#eth-bb-sub").textContent = `+${state.amounts.eth} on starknet`;
    $("#eth-press-btn").disabled = false;

    const bal = await state.ethProvider.getBalance(addr);
    if (bal === 0n) toast("ETH burner has 0 — fund it before pressing", "err");
  } catch (e) {
    console.error("eth setup:", e);
    $("#eth-bb-sub").textContent = "eth setup failed";
    toast("eth burner setup failed", "err");
  }
}

// --- Starknet side setup -----------------------------------------------------
async function setupStarknet() {
  try {
    if (!CONFIG.STARKNET_BURNER_PRIVATE_KEY || !CONFIG.STARKNET_BURNER_ADDRESS)
      throw new Error("STARKNET_BURNER_* missing");
    state.snProvider = new RpcProvider({
      nodeUrl: CONFIG.STARKNET_RPC,
      blockIdentifier: "latest",      // Alchemy 0.8 doesn't accept "pending"
      specVersion: CONFIG.STARKNET_SPEC || "0.8.1",
    });
    state.snAccount = new Account(
      state.snProvider,
      CONFIG.STARKNET_BURNER_ADDRESS,
      CONFIG.STARKNET_BURNER_PRIVATE_KEY,
    );
    const snEl = $("#sn-account");
    snEl.innerHTML =
      `<span class="sn-acct-short">${shortFelt(CONFIG.STARKNET_BURNER_ADDRESS)}</span> <span class="burner-tag">burner</span>`;
    makeCopyable(snEl.querySelector(".sn-acct-short"), CONFIG.STARKNET_BURNER_ADDRESS);
    snEl.appendChild(copyButton(CONFIG.STARKNET_BURNER_ADDRESS));
    $("#sn-bb-sub").textContent = `+${state.amounts.sn} on ethereum`;
    $("#sn-press-btn").disabled = false;
  } catch (e) {
    console.error("sn setup:", e);
    $("#sn-bb-sub").textContent = "sn setup failed";
    toast("sn burner setup failed", "err");
  }
}

// --- ETH → Starknet press ----------------------------------------------------
async function onPressEth() {
  const btn = $("#eth-press-btn");
  const sub = $("#eth-bb-sub");
  sub.dataset.locked = "1";
  btn.classList.add("is-tx");
  document.querySelector(".bridge").classList.add("is-tx");
  sub.textContent = "quoting…";
  let entry = null;
  try {
    const by = state.amounts.eth;
    const options = await state.ethTrigger.defaultOptions();
    const fee = await state.ethTrigger.quoteTriggerIncrement(CONFIG.DST_EID_STARKNET, by, options);
    sub.textContent = `fee ${ethers.formatEther(fee.nativeFee).slice(0, 8)} ETH — sending…`;

    const tx = await state.ethTrigger.triggerIncrement(
      CONFIG.DST_EID_STARKNET, by, options,
      { value: fee.nativeFee },
    );
    entry = { side: "eth->sn", startedAt: Date.now(), by, ethTx: tx.hash, status: "pending" };
    state.txs.unshift(entry); renderLog();
    sub.textContent = "sent — confirming…";
    toast(`ETH tx ${shortAddr(tx.hash)} submitted`, "ok");

    const receipt = await tx.wait();
    entry.status = receipt.status === 1 ? "eth-ok" : "failed";
    renderLog();
    if (entry.status === "failed") throw new Error("eth tx reverted");
    sub.textContent = "confirmed — relaying…";

    const target = state.snCount + by;
    if (!await pollUntil("sn", target, 6 * 60 * 1000)) {
      sub.textContent = "timed out";
      toast("eth→sn not delivered in 6 min", "err");
    } else {
      const lat = Math.round((Date.now() - entry.startedAt) / 1000);
      entry.status = "delivered"; entry.latencySec = lat; renderLog();
      sub.textContent = `delivered +${by} in ${lat}s`;
      toast(`eth→sn +${by} in ${lat}s`, "ok");
    }
  } catch (e) {
    console.error(e);
    if (entry) { entry.status = "failed"; renderLog(); }
    sub.textContent = "error";
    toast(e.shortMessage || e.message || "failed", "err");
  } finally {
    btn.classList.remove("is-tx");
    document.querySelector(".bridge").classList.remove("is-tx");
    setTimeout(() => { delete sub.dataset.locked; }, 8000);
  }
}

// --- Starknet → ETH press ----------------------------------------------------
async function onPressSn() {
  const btn = $("#sn-press-btn");
  const sub = $("#sn-bb-sub");
  sub.dataset.locked = "1";
  btn.classList.add("is-tx");
  document.querySelector(".bridge").classList.add("is-tx");
  sub.textContent = "quoting…";
  let entry = null;
  try {
    const by = state.amounts.sn;
    const gasLimit = 200000n;

    // quote (read-only call via raw RPC — cheaper than estimating)
    const quoteRes = await starknetCall(
      CONFIG.STARKNET_RPC,
      CONFIG.COUNTER_ADDRESS,
      SELECTORS.quote_trigger_increment,
      [
        "0x" + CONFIG.DST_EID_ETHEREUM.toString(16),
        "0x" + BigInt(by).toString(16),
        "0x" + gasLimit.toString(16),
      ],
    );
    // MessagingFee { native_fee: u256 (low, high), lz_token_fee: u256 (low, high) }
    const nativeFee = (BigInt(quoteRes[0]) | (BigInt(quoteRes[1]) << 128n));
    sub.textContent = `fee ${(Number(nativeFee) / 1e18).toFixed(6)} STRK — sending…`;

    // BRANCH: privacy mode routes the call through the Tier-2 account; otherwise
    // the existing burner signs directly.
    let snTx;
    if (state.privacy) {
      if (state.tier2Stage !== "ready") {
        throw new Error("Tier-2 not ready. Complete the 4 steps in the privacy panel first.");
      }
      tier2Log(`──── press: sn→eth +${by} via Tier-2 ────`);
      const result = await state.tier2.triggerIncrementViaTier2({
        counterAddress: CONFIG.COUNTER_ADDRESS,
        dstEid: CONFIG.DST_EID_ETHEREUM,
        by,
        gasLimit,
        lzNativeFee: nativeFee,
        strkAddress: CONFIG.STRK_ADDRESS,
        log: tier2Log,
      });
      snTx = result.txHash;
    } else {
      const call = {
        contractAddress: CONFIG.COUNTER_ADDRESS,
        entrypoint: "trigger_increment",
        calldata: [
          CONFIG.DST_EID_ETHEREUM.toString(),
          by.toString(),
          gasLimit.toString(),
        ],
      };
      ({ transaction_hash: snTx } = await state.snAccount.execute([call]));
    }
    entry = {
      side: "sn->eth",
      startedAt: Date.now(),
      by,
      snTx,
      status: "pending",
      privacy: state.privacy,
    };
    state.txs.unshift(entry); renderLog();
    sub.textContent = state.privacy ? "sent via Tier-2 — confirming…" : "sent — confirming…";
    toast(`SN tx ${shortFelt(snTx)} submitted`, "ok");

    await state.snProvider.waitForTransaction(snTx);
    entry.status = "sn-ok"; renderLog();
    sub.textContent = "confirmed — relaying…";

    const target = state.ethCount + by;
    if (!await pollUntil("eth", target, 8 * 60 * 1000)) {
      sub.textContent = "timed out";
      toast("sn→eth not delivered in 8 min", "err");
    } else {
      const lat = Math.round((Date.now() - entry.startedAt) / 1000);
      entry.status = "delivered"; entry.latencySec = lat; renderLog();
      sub.textContent = `delivered +${by} in ${lat}s`;
      toast(`sn→eth +${by} in ${lat}s`, "ok");
    }
  } catch (e) {
    console.error(e);
    if (entry) { entry.status = "failed"; renderLog(); }
    sub.textContent = "error";
    const msg = e?.message || String(e);
    toast(msg.includes("ERC20") ? "STRK allowance? approve more" : msg.slice(0, 80), "err");
  } finally {
    btn.classList.remove("is-tx");
    document.querySelector(".bridge").classList.remove("is-tx");
    setTimeout(() => { delete sub.dataset.locked; }, 8000);
  }
}

// --- TIER 2 PRIVACY MODE -----------------------------------------------------
function setTier2AddrDisplay(addr) {
  // Step 3: short + copy button
  const el = $("#tier2-account-addr");
  if (el) {
    el.innerHTML = `<span class="tier2-acct-short">${shortFelt(addr)}</span>`;
    makeCopyable(el.querySelector(".tier2-acct-short"), addr);
    el.appendChild(copyButton(addr));
  }
  // Step 4: prepend "send to: <short>+copy" inside the balance value cell so
  // the user has the address right next to the funding label/balance.
  const balEl = $("#tier2-strk-bal");
  if (balEl && !balEl.dataset.hasAddr) {
    balEl.dataset.hasAddr = "1";
    const balText = balEl.textContent;
    balEl.innerHTML =
      `<span class="tier2-fund-row"><span class="tier2-fund-label">send to</span> ` +
      `<span class="tier2-fund-addr-short">${shortFelt(addr)}</span></span>` +
      `<span class="tier2-fund-bal">${balText}</span>`;
    const hintAddr = balEl.querySelector(".tier2-fund-addr-short");
    if (hintAddr) {
      makeCopyable(hintAddr, addr);
      balEl.querySelector(".tier2-fund-row").appendChild(copyButton(addr));
    }
  }
}

// Update only the balance number portion of step 4's value cell, without
// destroying the address row above it.
function setTier2BalDisplay(balText) {
  const balEl = $("#tier2-strk-bal");
  if (!balEl) return;
  const inner = balEl.querySelector(".tier2-fund-bal");
  if (inner) inner.textContent = balText;
  else balEl.textContent = balText;
}

function tier2Log(line) {
  const el = $("#tier2-log");
  if (!el) return;
  el.hidden = false;
  const ts = new Date().toISOString().slice(11, 23);
  el.textContent += `[${ts}] ${line}\n`;
  el.scrollTop = el.scrollHeight;
}

function ensureTier2Adapter() {
  if (state.tier2) return state.tier2;
  const required = [
    "TIER2_STARKNET_RPC", "TIER2_POOL_ADDRESS", "TIER2_POOL_FEE_TOKEN",
    "TIER2_DISCOVERY_URL", "TIER2_PROVING_URL", "TIER2_PAYMASTER_API_KEY",
    "TIER2_FACTORY_ADDRESS", "TIER2_HELPER_ADDRESS", "TIER2_INVOKE_HELPER_ADDRESS",
    "TIER2_ALICE_ADDRESS", "TIER2_ALICE_PRIVATE_KEY", "TIER2_ALICE_VIEWING_KEY",
  ];
  const missing = required.filter((k) => !CONFIG[k]);
  if (missing.length) {
    throw new Error(`config.js missing TIER 2 keys: ${missing.join(", ")}`);
  }
  state.tier2 = new Tier2Adapter({
    starknetRpcUrl:       CONFIG.TIER2_STARKNET_RPC,
    starknetChainId:      CONFIG.TIER2_STARKNET_CHAIN_ID,
    network:              CONFIG.TIER2_NETWORK,
    poolAddress:          CONFIG.TIER2_POOL_ADDRESS,
    poolFeeToken:         CONFIG.TIER2_POOL_FEE_TOKEN,
    discoveryUrl:         CONFIG.TIER2_DISCOVERY_URL,
    provingUrl:           CONFIG.TIER2_PROVING_URL,
    paymasterUrl:         CONFIG.TIER2_PAYMASTER_URL,
    paymasterApiKey:      CONFIG.TIER2_PAYMASTER_API_KEY,
    factoryAddress:       CONFIG.TIER2_FACTORY_ADDRESS,
    helperAddress:        CONFIG.TIER2_HELPER_ADDRESS,
    invokeHelperAddress:  CONFIG.TIER2_INVOKE_HELPER_ADDRESS,
    alice: {
      address:    CONFIG.TIER2_ALICE_ADDRESS,
      privateKey: CONFIG.TIER2_ALICE_PRIVATE_KEY,
      viewingKey: CONFIG.TIER2_ALICE_VIEWING_KEY,
    },
  });
  return state.tier2;
}

function setStage(stage) {
  state.tier2Stage = stage;
  const pill = $("#tier2-stage-pill");
  if (pill) {
    pill.textContent = stage.replace(/-/g, " ");
    pill.classList.toggle("is-ok",   stage === "ready" || stage === "deployed");
    pill.classList.toggle("is-warn", stage === "deployed"); // deployed but maybe unfunded
  }
  // Each step row reflects whether its sub-stage is done.
  $("#tier2-panel").querySelectorAll(".tier2-step").forEach((row) => {
    const s = row.dataset.step;
    const done =
      (s === "connect" && stageReached(stage, "mm-connected")) ||
      (s === "derive"  && stageReached(stage, "session-derived")) ||
      (s === "deploy"  && stageReached(stage, "deployed")) ||
      (s === "fund"    && stage === "ready");
    row.classList.toggle("is-done", !!done);
  });
}
function stageReached(cur, target) {
  const order = ["setup", "mm-connected", "session-derived", "deployed", "ready"];
  return order.indexOf(cur) >= order.indexOf(target);
}

function renderPrivacyButton() {
  const btn = $("#privacy-toggle");
  const st = $("#privacy-toggle-state");
  btn.setAttribute("aria-pressed", state.privacy ? "true" : "false");
  st.textContent = state.privacy ? "ON" : "OFF";
}

function renderSnAccountLabel() {
  const snEl = $("#sn-account");
  if (!snEl) return;
  if (state.privacy) {
    if (state.tier2AccountAddr) {
      snEl.innerHTML =
        `<span class="sn-acct-short">${shortFelt(state.tier2AccountAddr)}</span> ` +
        `<span class="burner-tag" style="background:var(--accent);color:var(--bg);">tier-2</span>`;
      makeCopyable(snEl.querySelector(".sn-acct-short"), state.tier2AccountAddr);
      snEl.appendChild(copyButton(state.tier2AccountAddr));
    } else {
      snEl.innerHTML =
        `<span class="sn-acct-short">— set up in panel —</span> ` +
        `<span class="burner-tag" style="background:var(--warn);color:var(--bg);">tier-2</span>`;
    }
  } else {
    snEl.innerHTML =
      `<span class="sn-acct-short">${shortFelt(CONFIG.STARKNET_BURNER_ADDRESS)}</span> <span class="burner-tag">burner</span>`;
    makeCopyable(snEl.querySelector(".sn-acct-short"), CONFIG.STARKNET_BURNER_ADDRESS);
    snEl.appendChild(copyButton(CONFIG.STARKNET_BURNER_ADDRESS));
  }
}

async function onPrivacyToggle() {
  state.privacy = !state.privacy;
  try { localStorage.setItem(PRIVACY_STORAGE_KEY, state.privacy ? "1" : "0"); } catch {}
  renderPrivacyButton();
  $("#tier2-panel").hidden = !state.privacy;
  renderSnAccountLabel();
}

async function onTier2Connect() {
  try {
    const adapter = ensureTier2Adapter();
    tier2Log("connecting MetaMask…");
    const { mmAddress } = await adapter.connectMm();
    state.tier2MmAddr = mmAddress;
    $("#tier2-mm-addr").textContent = shortAddr(mmAddress);
    $("#tier2-derive-btn").disabled = false;
    setStage("mm-connected");
    tier2Log(`  mm=${mmAddress}`);
  } catch (e) {
    console.error(e);
    toast(e.message || "MM connect failed", "err");
    tier2Log(`ERROR: ${e.message}`);
  }
}

async function onTier2Derive() {
  try {
    const adapter = ensureTier2Adapter();
    tier2Log("personal_sign bootstrap message…");
    const { sessionEthAddress } = await adapter.deriveSession();
    state.tier2SessionAddr = sessionEthAddress;
    $("#tier2-session-addr").textContent = shortAddr(sessionEthAddress);
    tier2Log(`  session=${sessionEthAddress}`);

    // Compute the Starknet account address client-side and check if it's already deployed.
    const addr = adapter.computeTier2Address();
    state.tier2AccountAddr = addr;
    setTier2AddrDisplay(addr);
    tier2Log(`  predicted tier-2 acct=${addr}`);

    tier2Log("checking on-chain deployment status…");
    const alreadyDeployed = await adapter.isDeployed();
    if (alreadyDeployed) {
      tier2Log("  already deployed — skipping deploy step");
      $("#tier2-refresh-bal-btn").disabled = false;
      setStage("deployed");
      await refreshTier2Balance();
    } else {
      $("#tier2-deploy-btn").disabled = false;
      setStage("session-derived");
    }
  } catch (e) {
    console.error(e);
    toast(e.message || "derive failed", "err");
    tier2Log(`ERROR: ${e.message}`);
  }
}

async function onTier2Deploy() {
  const btn = $("#tier2-deploy-btn");
  btn.disabled = true;
  try {
    const adapter = ensureTier2Adapter();
    tier2Log("sponsored private deploy via Alice…");
    const result = await adapter.deploy(tier2Log);
    state.tier2AccountAddr = result.tier2Address;
    setTier2AddrDisplay(result.tier2Address);
    tier2Log(`  deploy tx=${result.txHash}`);
    tier2Log(`  fee paid by Alice=${result.feePaidByAlice}`);
    toast("Tier-2 account deployed", "ok");
    setStage("deployed");
    $("#tier2-refresh-bal-btn").disabled = false;
    await refreshTier2Balance();
  } catch (e) {
    console.error(e);
    toast(e.message || "deploy failed", "err");
    tier2Log(`ERROR: ${e.message}`);
    btn.disabled = false;
  }
}

async function refreshTier2Balance() {
  try {
    const adapter = ensureTier2Adapter();
    const bal = await adapter.getTier2StrkBalance(CONFIG.STRK_ADDRESS);
    state.tier2StrkBal = bal;
    const strk = Number(bal) / 1e18;
    setTier2BalDisplay(`${strk.toFixed(4)} STRK`);
    // Need at least ~0.5 STRK to cover a typical LZ fee (~0.3 STRK on Sepolia).
    if (bal >= 500_000_000_000_000_000n) {
      setStage("ready");
      if (state.privacy) renderSnAccountLabel();
    } else {
      setStage("deployed");
      tier2Log(`  current STRK balance=${strk.toFixed(4)} — fund with 1+ STRK to enable presses`);
    }
  } catch (e) {
    console.error(e);
    tier2Log(`balance check failed: ${e.message}`);
  }
}

function setupTier2() {
  // Restore toggle state.
  try { state.privacy = localStorage.getItem(PRIVACY_STORAGE_KEY) === "1"; } catch {}
  renderPrivacyButton();
  $("#tier2-panel").hidden = !state.privacy;
  setStage("setup");

  $("#privacy-toggle").addEventListener("click", onPrivacyToggle);
  $("#tier2-connect-btn").addEventListener("click", onTier2Connect);
  $("#tier2-derive-btn").addEventListener("click", onTier2Derive);
  $("#tier2-deploy-btn").addEventListener("click", onTier2Deploy);
  $("#tier2-refresh-bal-btn").addEventListener("click", refreshTier2Balance);
}

// --- ABA V3 readers ----------------------------------------------------------
async function readEthCountV3() {
  const c = new ethers.Contract(CONFIG.COUNTER_V3_ETH, COUNTER_V3_ABI, state.ethProvider);
  return Number(await c.count());
}

async function readSnCountV3() {
  const selector = snKeccak("count");
  const [c] = await starknetCall(CONFIG.STARKNET_RPC, CONFIG.COUNTER_V3_SN, selector);
  return Number(BigInt(c));
}

// Periodic refresh used by boot() to keep the ABA-zone count displays live.
let abaCountSn = null, abaCountEth = null;
async function refreshAbaCounts() {
  try {
    const sn = await readSnCountV3();
    if (sn !== abaCountSn) { abaCountSn = sn; renderDigits("aba-sn", sn); }
  } catch (e) { /* swallow RPC blips */ }
  try {
    const eth = await readEthCountV3();
    if (eth !== abaCountEth) { abaCountEth = eth; renderDigits("aba-eth", eth); }
  } catch (e) { /* swallow */ }
}

// pollUntilFn: generic promise-based poller (distinct from the existing pollUntil)
async function pollUntilFn(fn, timeoutMs, intervalMs = 5000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try { if (await fn()) return true; } catch (e) { console.warn("poll err:", e); }
    await new Promise((r) => setTimeout(r, intervalMs));
  }
  return false;
}

// --- ABA status helpers ------------------------------------------------------
function setAbaStatus(text) {
  document.getElementById("aba-status-text").textContent = text;
}
function setAbaTxLink(tx) {
  const el = document.getElementById("aba-tx-link");
  if (!tx) { el.innerHTML = ""; return; }
  el.innerHTML = `<a href="https://testnet.layerzeroscan.com/tx/${tx}" target="_blank" rel="noopener">${tx.slice(0, 10)}…${tx.slice(-8)}</a>`;
}

// --- ABA press handler -------------------------------------------------------
async function pressAba() {
  const btn = document.getElementById("aba-press-btn");
  btn.disabled = true;
  let entry = null;
  try {
    const bySn  = BigInt(document.getElementById("aba-by-sn").value  || "1");
    const byEth = BigInt(document.getElementById("aba-by-eth").value || "1");

    setAbaStatus("quoting…");
    const trigger = new ethers.Contract(CONFIG.COUNTER_V3_ETH, COUNTER_V3_ABI, state.ethWallet);
    const options = await trigger.defaultAbaOptions();
    const fee = await trigger.quoteAbaIncrement(CONFIG.DST_EID_STARKNET, bySn, byEth, options);

    const preSn  = await readSnCountV3();
    const preEth = await readEthCountV3();

    setAbaStatus(`sending… (fee ${ethers.formatEther(fee.nativeFee)} ETH)`);
    const tx = await trigger.triggerAbaIncrement(
      CONFIG.DST_EID_STARKNET, bySn, byEth, options, { value: fee.nativeFee },
    );
    setAbaTxLink(tx.hash);

    entry = {
      side: "aba",
      startedAt: Date.now(),
      bySn: Number(bySn),
      byEth: Number(byEth),
      ethTx: tx.hash,
      status: "pending",
    };
    state.txs.unshift(entry); renderLog();

    await tx.wait();
    entry.status = "eth-ok"; renderLog();

    setAbaStatus("waiting for Starknet (~60s)…");
    const snOk = await pollUntilFn(
      async () => (await readSnCountV3()) >= preSn + Number(bySn),
      5 * 60_000, 8_000,
    );
    if (!snOk) {
      setAbaStatus("timed out waiting for Starknet");
      entry.status = "timed-out"; renderLog();
      return;
    }
    entry.status = "aba-half"; renderLog();

    setAbaStatus(`Starknet confirmed +${bySn}, waiting for Ethereum (~3.5min)…`);
    const ethOk = await pollUntilFn(
      async () => (await readEthCountV3()) >= preEth + Number(byEth),
      8 * 60_000, 12_000,
    );
    if (!ethOk) {
      setAbaStatus("timed out waiting for Ethereum return");
      entry.status = "timed-out"; renderLog();
      return;
    }

    const lat = Math.round((Date.now() - entry.startedAt) / 1000);
    entry.status = "delivered"; entry.latencySec = lat; renderLog();
    setAbaStatus(`done — SN +${bySn}, ETH +${byEth}`);
  } catch (err) {
    console.error(err);
    if (entry) { entry.status = "failed"; renderLog(); }
    setAbaStatus(`error: ${err.shortMessage || err.message}`);
  } finally {
    btn.disabled = false;
  }
}

// --- Polling -----------------------------------------------------------------
async function pollUntil(side, target, deadlineMs) {
  const start = Date.now();
  while (Date.now() - start < deadlineMs) {
    await new Promise((r) => setTimeout(r, 4000));
    if (side === "sn") await refreshStarknetCount();
    else                await refreshEthCount();
    if ((side === "sn" ? state.snCount : state.ethCount) >= target) return true;
  }
  return false;
}

async function refreshStarknetCount() {
  try {
    const [c] = await starknetCall(CONFIG.STARKNET_RPC, CONFIG.COUNTER_ADDRESS, SELECTORS.count);
    const n = Number(BigInt(c));
    if (n !== state.snCount) { state.snCount = n; renderDigits("sn", n); }
    try {
      const [b] = await starknetCall(CONFIG.STARKNET_RPC, CONFIG.COUNTER_ADDRESS, SELECTORS.last_increment_by);
      state.snLastBy = Number(BigInt(b));
      $("#sn-last-by").textContent = state.snLastBy ? `+${state.snLastBy}` : "—";
    } catch {}
    try {
      const [e] = await starknetCall(CONFIG.STARKNET_RPC, CONFIG.COUNTER_ADDRESS, SELECTORS.last_src_eid);
      state.snLastEid = Number(BigInt(e));
      $("#sn-last-eid").textContent = state.snLastEid || "—";
    } catch {}
  } catch (e) { /* silent */ }
}

async function refreshEthCount() {
  try {
    if (!state.ethTrigger) return;
    const c = Number(await state.ethTrigger.count());
    if (c !== state.ethCount) { state.ethCount = c; renderDigits("eth", c); }
    const b = Number(await state.ethTrigger.lastIncrementBy());
    state.ethLastBy = b;
    $("#eth-last-by").textContent = b ? `+${b}` : "—";
    const e = Number(await state.ethTrigger.lastSrcEid());
    state.ethLastEid = e;
    $("#eth-last-eid").textContent = e || "—";
  } catch {}
}

// --- Log render --------------------------------------------------------------
function renderLog() {
  persistLog();

  const ol         = $("#log-list");
  const metaEl     = $("#log-meta");
  const expandBtn  = $("#log-expand-btn");
  const clearBtn   = $("#log-clear-btn");
  const total      = state.txs.length;

  if (metaEl) {
    if (total === 0) {
      metaEl.textContent = "0 transmissions";
    } else if (state.logExpanded || total <= LOG_COLLAPSED_LIMIT) {
      metaEl.textContent = `${total} transmission${total === 1 ? "" : "s"}`;
    } else {
      metaEl.textContent = `showing ${LOG_COLLAPSED_LIMIT} of ${total}`;
    }
  }

  if (expandBtn) {
    const overflow = total > LOG_COLLAPSED_LIMIT;
    expandBtn.hidden = !overflow;
    expandBtn.textContent = state.logExpanded ? "COLLAPSE" : `EXPAND ALL (${total})`;
  }
  if (clearBtn) clearBtn.hidden = total === 0;

  ol.innerHTML = "";
  if (total === 0) {
    const li = document.createElement("li");
    li.className = "log-empty";
    li.textContent = "No transmissions yet. Press a button.";
    ol.appendChild(li);
    return;
  }

  const visible = state.logExpanded ? state.txs : state.txs.slice(0, LOG_COLLAPSED_LIMIT);

  for (const tx of visible) {
    const li = document.createElement("li");
    const t = new Date(tx.startedAt);
    const dStr = t.toLocaleDateString(undefined, { month: "short", day: "2-digit" });
    const hhmmss = [t.getHours(), t.getMinutes(), t.getSeconds()]
      .map((x) => String(x).padStart(2, "0")).join(":");

    let dir, amountText;
    if (tx.side === "eth->sn") {
      dir = "ETH → SN"; amountText = `+${tx.by}`;
    } else if (tx.side === "sn->eth") {
      dir = "SN → ETH"; amountText = `+${tx.by}`;
    } else if (tx.side === "aba") {
      dir = "ABA ⇄";    amountText = `SN+${tx.bySn} · ETH+${tx.byEth}`;
    } else {
      dir = tx.side;    amountText = tx.by != null ? `+${tx.by}` : "";
    }

    const statusText = {
      pending:    "PENDING",
      "eth-ok":   "ON ETH ✓",
      "sn-ok":    "ON SN ✓",
      delivered:  tx.latencySec != null ? `DELIVERED · ${tx.latencySec}s` : "DELIVERED",
      "aba-half": "SN LEG ✓",
      failed:     "FAILED",
      "timed-out":"TIMED OUT",
    }[tx.status] || (tx.status ? tx.status.toUpperCase() : "?");

    const txHash = tx.ethTx || tx.snTx || "";
    const link = txHash ? `https://testnet.layerzeroscan.com/tx/${txHash}` : "#";
    const linkText = shortAddr(txHash);

    li.innerHTML = `
      <span class="log-time"><span class="log-date">${dStr}</span> ${hhmmss}</span>
      <span class="log-amount">${dir} ${amountText}</span>
      <span class="log-status ${tx.status}">${statusText}</span>
      <span class="log-tx">${txHash ? `<a href="${link}" target="_blank" rel="noopener">${linkText} ↗</a>` : "—"}</span>
    `;
    ol.appendChild(li);
  }
}

boot().catch((e) => { console.error(e); toast(e.message || "boot failed", "err"); });
