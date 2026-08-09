# Bucket V2 audit notes — commit 74b28e1 (zip-verified identical to working copy)

Scope: bucket_framework, bucket_usd, bucket_oracle, bucket_cdp, bucket_psm, bucket_flash.
Methodology: state-transition + invariant, per-path, no random reading. A hypothesis is only
promoted to a report when `confirmed + runnable PoC + current on-chain financial impact`.

---

## H-01: user receives more USDB than their debt increase (or repays less USDB than debt decrease)
**Location:** `bucket_cdp/sources/vault.move` `update_position` L392-495 (mint/burn block L468-490).
**Invariant:** net USDB delivered to caller == increase in position debt; USDB removed from
circulation on repay == decrease in *minted* debt (pending interest excluded, since it was never minted).

**Per-path trace** (request values: `B`=borrow, `R`=repayment.value()):
| branch | condition | mint/burn | usdb_out value | user handed in | net USDB to user | debt Δ (L394/398/403) |
|---|---|---|---|---|---|---|
| A | `B > R` | mint `B−R` | `(B−R)+R = B` | `R` | `B−R` | `B−R` |
| B | `B ≤ R` | burn `R−B−claimable`; `claimable`→treasury | `B` | `R` | `B−R` | `B−R` |

- Net USDB to user = `B − R` in **both** branches = exact debt change. No path yields USDB > debt increase.
- Case A: the repayment `R` round-trips (returned joined to output); equivalent to a plain borrow of `B−R`.
- Case B: `claimable = min(R−B, total_pending_interest_amount)`; bounded by real pending interest
  (accrued in `collect_interest` as debt-without-mint), so routing it to treasury instead of burning
  is correct and cannot be inflated by the caller.

**Supply cap:** every mint flows through `mint_usdb` → `limited_supply.increase` (Move-overflow-safe,
re-checks the limit); interest mint is `min(total_interest, increasable_amount)` so the cap is never
exceeded (excess → pending). No unbacked mint, no cap bypass.

**Status: DISPROVED (verified balanced line-by-line).** Empirical PoC: `test_mint_debt_symmetry_*`.

---

## H-08: cross-module composition (flash → PSM/CDP → repay) creates value
**Hypothesis:** an atomic PTB combining a flash-mint with PSM/CDP ops extracts value that no
single module allows.
**Reasoning:** value conservation composes — each primitive is value-neutral (flash: hot-potato
requires `mint+fee` back; PSM: par swap minus floors/ceil fees; CDP: minted == debt). A composition
of value-neutral steps cannot create value; conversions are par-minus-fees, and there is no
in-protocol mispricing to exploit (single-source Pyth, un-manipulable).
**PoC:** `bucket_psm/tests/composite_flash_tests.move::test_flash_psm_roundtrip_no_arbitrage` —
flash-mint B, `swap_out → swap_in` at ZERO PSM fees and 1:1 decimals, then repay: round-trip returns
`r <= B` and `r < B + fee`, so the attacker must inject `shortfall = B+fee-r > 0` to close the
receipt → strict net loss. flash→CDP reduces to the same: flash USDB can only repay debt / be a
repayment coin, and unwinding collateral to USDB routes through the par PSM.
**Status: DISPROVED (runnable PoC).**

## H-09: emergency security level has no max / no monotonicity (`vault.move` set_security_by_manager L325-339)
`level` is a free `u8` with only `level == 0 || level < manager_level` rejected. A manager can set
`security_level = 255`; since the only action levels are 1 and 2, `check_security_level` (L823-825)
never aborts (`1>=255` and `2>=255` are false) → security is effectively OFF. A level-2 manager can
also overwrite a stricter level-1 emergency freeze with 2/255, weakening a higher authority's action.
**Real code defect (confirmed).** BUT the actor must hold a manager role, which is granted only by
`AdminCap` (`set_manager_role`). Not reachable by an external/unauthorized attacker → **out of the
Critical/High bounty definition** (authorized-insider / governance issue; defense-in-depth Low–Medium).
Fix: restrict levels to {1,2} (or witnesses), forbid loosening a stricter existing level, gate
emergency-release behind `AdminCap`.

## Critical-path checklist (verified against the code — all closed or out-of-scope)
The five preconditions for escalating the oracle finding to Critical, each checked:
1. **Multi-source aggregator live on mainnet** — NO. All 27 are single-source (`ONCHAIN_aggregator_weights.md`).
2. **A source permissionlessly manipulable** — UNASSESSABLE from scope: source adapters
   (`pyth_rule`/`scoin_rule`/…) are not in the repo. With single-source, a manipulable source would
   just pass its own value through (no filter amplification) — Pyth manipulation is out of scope anyway.
3. **Untrusted oracle object accepted by CDP** — NO (CLOSED). CDP takes a `PriceResult<T>` *value*
   (vault.move:349,556,668), not a `PriceAggregator`. `PriceResult` constructors are `result::new`
   (`public(package)`) and `aggregate()`; the latter needs an aggregator (ListingCap-only) + registered
   source witnesses. One aggregator per coin type (`listing::register` → `EAlreadyListed`). Attacker
   cannot forge, self-create, register a 2nd, or inject a source.
4. **`ListingCap` / admin capability leak** — NO. `listing::init` transfers the single cap to the
   deployer at publish; no public mint. (Leakage would be an operational failure outside the code.)
5. **Unlimited borrow/mint path** — NO. Mint == debt (H-01, PoC); borrow gated by CR check.

⇒ **Critical is not reachable from in-scope code at the current deployment.** The oracle defect stays
a latent multi-source fault-tolerance failure. Would require a future ≥2-source deployment AND ≥2
attacker-influenceable sources AND a large exposed vault to become High/Critical.

## Closed / latent (do NOT submit)
- **Oracle mean-vs-median** (`aggregator.move:265-280`): real logic defect. NOW characterized more
  sharply — a **sacrifice/bait source** lets an attacker coalition of ~10% weight defeat an honest
  89% supermajority (`test_sacrifice_source_minority_controls_price`); the "single source > 50%"
  bar was wrong. Precondition: attacker sets prices of ≥ 2 registered sources (bait + rider,
  rider weight ≥ threshold). STILL not currently exploitable: ALL 27 mainnet aggregators are
  single-source (threshold 1, one rule) → nothing to filter. See `ONCHAIN_aggregator_weights.md`.
  Latent; reachable only if a ≥2-source aggregator is ever configured AND ≥2 of its sources are
  attacker-influenceable. Do not submit as paid severity now.

## Verified sound this session (multi-lens, config-independent)
mint witness gating (`public(package)`, empty structs — unforgeable) · limited_supply (overflow-safe) ·
PSM par swap (fees ceil, floors) · flash mint/burn (hot-potato, exact repay) · sheet/liability
(matched credit/debt) · linked_table (standard, private field) · account identity (ACC-2 fix, owned) ·
acl (package-gated) · interest accumulator (total_debt leads → no underflow; conservative) ·
position_is_healthy decimals (truncate-down → conservative) · request/response locker (no reentrancy).

---

## AUDIT STATUS — attacker-profit-path sweep (in-scope packages exhausted)

Goal for this pass: find a path where an ATTACKER extracts value (not a protocol-favoring
rounding drift). Swept every money path in the in-scope zip:

- **vault.update_position** (borrow/repay/withdraw): health check `icr = coll*price/debt >= MCR`
  runs post-mutation via `get_position_data` (live debt incl. interest). `float.mul/div` round DOWN
  ⇒ icr rounded down ⇒ check is *stricter* ⇒ protocol-safe. No under-collateralized borrow.
- **vault.liquidate**: withdraw = ceil(repay*coll/debt), capped at coll; requires position unhealthy.
  Liquidator profit bounded to (coll*price/debt − 1) < MCR−1 = 10%. Intended incentive. ceil bonus ≤1 unit.
- **PSM swap_in/out**: both directions `floor()`; round-trip loses dust; `check_price` gates on
  |price−1| ≤ tolerance. No arbitrage. `sheet` unused in swap path.
- **float (1e9) / double (1e18)**: comprehensive overflow guards on add/mul/div/mul_u64/ceil/round;
  from_fraction can't overflow u128/u256. No wrap.
- **limited_supply.increase**: enforces cap (aborts > limit) — real, not cosmetic.
- **account.AccountRequest**: mintable only for `ctx.sender()` or an owned `Account` (id-address);
  impersonation bug already fixed (`// FIXED: ACC-2`). No forging another debtor.
- **oracle aggregator/collector**: `collector.collect<T,R>` is public and takes an arbitrary
  `price: Option<Float>`, BUT aggregate/remove_outliers only count rules present in `self.weights`
  (configured). Injected rules (unknown witness type) get weight 0 and are removed before the
  weighted-avg is computed ⇒ cannot shift the price. To feed a CONFIGURED rule you must hold that
  rule's witness `R: drop`, constructed only by its adapter module.

**Conclusion:** no attacker-profit High/Critical exists in the IN-SCOPE code. Only confirmed bug is
the interest rounding drift → Low, protocol-favoring, no attacker gain (PoC: poc_interest_overmint.move).

**Highest remaining lead = OUT OF SCOPE of the provided zip:** the oracle *rule adapter* modules
(PythRule / SCoinRule / GCoinRule / BfBtcRule) that (a) construct the rule witness and (b) compute the
`Float` price handed to `collector.collect`. A decimal/expo/confidence mis-scaling in ANY adapter =
mispriced collateral = borrow unbacked USDB = Critical. These modules are NOT in bucket-audit/. Need
their sources (Bucket GitHub oracle-adapter package) to continue the profit-path hunt.

---

## Novel-lens sweep: the "invisible files" (Treasury + custom linked_table)

Methodology: audit the files researchers SKIP because they assume they're stdlib copies or
plumbing. Two candidates carried real catastrophe potential; both verified closed.

### usdb.move (Treasury — the single USDB mint authority for ALL modules)
- `mint<M: drop>` / `burn<M: drop>`: gated by (a) caller must hold witness of type `M`
  (package-private per module ⇒ unforgeable) AND (b) `assert_valid_module_version<M>` (M registered
  + version whitelisted by AdminCap). Both mint & burn update `TreasuryCap.total_supply` AND
  `module_config[M].limited_supply` by the same amount ⇒ invariant
  `cap.total_supply == Σ_M module_supply` is preserved. Sound.
- Safe defaults: `add_version` w/o `set_supply_limit` ⇒ limit 0 ⇒ mint aborts. `set_supply_limit`
  w/o version ⇒ version check aborts. Can't mint without BOTH set by admin.
- `collect<T,M>` / `claim<T,M>`: collect needs M-witness (donate under own module only); claim
  gated by `beneficiary_address`. No cross-module theft. df keyed by `get<T>()` ⇒ type-safe.
- **Liveness note (out of scope — DoS):** `collect_interest` caps interest to the VAULT's
  increasable_amount, but `treasury.mint` independently checks the TREASURY CDP-module cap. If
  admin sets treasury CDP cap < Σ vault caps, a full treasury cap makes `treasury.mint` abort inside
  `accrue_interest` ⇒ update_position aborts ⇒ repay/withdraw/liquidate all brick until admin raises
  the cap. Admin-config-dependent, not attacker-profit, DoS explicitly out of scope. Noted only.

### linked_table.move (custom fork — holds the CDP position_table)
- Fork of Sui stdlib + added positional `insert_front(next_k,…)` / `insert_back(prev_k,…)`.
  Splice logic correct: aborts on duplicate key (df::add), aborts on missing anchor (prev/next
  borrow), head/tail updated correctly. `remove` matches stdlib.
- **Key finding: ordering is NOT financially load-bearing.** vault re-inserts each touched position
  before its original successor (preserves insertion order, not CR-sorted). Liquidation targets a
  caller-named debtor; there is no redemption-queue or "lowest-CR-first" consumer of the order. So
  even a hypothetical ordering corruption yields zero fund impact. Closed.

### Verdict of the whole in-scope sweep
Mature, defensively-written codebase with visible prior audit fixes (ACC-2). No attacker-profit
High/Critical in scope. Confirmed real bugs: interest rounding drift (Low, protocol-favoring) and
liquidation ceil dust (Low, needs exotic low-decimal high-unit-value collateral that Sui assets
don't provide). The only surface that could host a profit Critical — the oracle price *rule
adapters* — is not in this repo.
