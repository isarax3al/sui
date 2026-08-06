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
