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

## Closed / latent (do NOT submit)
- **Oracle mean-vs-median** (`aggregator.move:265-280`): real logic defect, but ALL 27 mainnet
  aggregators are single-source (threshold 1, one rule) → outlier filter is a no-op → not currently
  exploitable. See `ONCHAIN_aggregator_weights.md`. Latent; reachable only if a ≥2-source aggregator
  with a source ≥ threshold is ever configured. Low/Informational at most.

## Verified sound this session (multi-lens, config-independent)
mint witness gating (`public(package)`, empty structs — unforgeable) · limited_supply (overflow-safe) ·
PSM par swap (fees ceil, floors) · flash mint/burn (hot-potato, exact repay) · sheet/liability
(matched credit/debt) · linked_table (standard, private field) · account identity (ACC-2 fix, owned) ·
acl (package-gated) · interest accumulator (total_debt leads → no underflow; conservative) ·
position_is_healthy decimals (truncate-down → conservative) · request/response locker (no reentrancy).
