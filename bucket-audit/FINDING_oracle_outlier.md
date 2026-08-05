# Oracle outlier-rejection is mean-based (not median) — anomalous source dominates the aggregate, enabling under-collateralized borrows

## Summary
`bucket_oracle::aggregator::remove_outliers` detects "abnormal" prices by comparing every
source price to the **weighted mean** of all prices. Because the mean is itself pulled
toward an anomalous price, a source with a large enough weight share is **not** filtered —
instead the honest sources are flagged as outliers and removed, and the anomalous price
**dominates** the final aggregated price. The code's own field comment says the tolerance is
a *"deviation from the median price"*, but the implementation uses the mean, so the behavior
differs from the intended/described design.

Because the aggregated price feeds `bucket_cdp::vault::position_is_healthy` (collateral-ratio
check) and `bucket_psm::pool::check_price`, an inflated aggregate lets a user borrow far more
USDB than their collateral is truly worth → under-collateralized debt / bad debt → loss of
funds for the protocol.

## Scope
- In scope: file is in the audited repo (`bucket_oracle/sources/aggregator.move`), not an imported contract.
- Matches: **"Attacks on logic (behavior of the code is different from the business description)"**
  (README: *"Outlier Detection … Automatic filtering of abnormal prices"*; code comment: *"median"*;
  implementation: mean) and, given a manipulable weighted source, **"loss of funds"**.

## Affected code
`bucket_oracle/sources/aggregator.move`
- L73: `outlier_tolerance: Float, // Maximum allowed deviation from the median price`  ← says *median*
- L265: `let weighted_avg = rules.fold!(... price.mul_u64(weight) ...).div_u64(total_weight);` ← uses **mean**
- L280: `weighted_avg.diff(price).div(weighted_avg).gt(self.outlier_tolerance())` ← compares each price to the skewed mean

Consumers of the aggregated price:
- `bucket_cdp/sources/vault.move` → `position_is_healthy` (L664-683) → `update_position` borrow gate.
- `bucket_psm/sources/pool.move` → `check_price` (L276-281).

## Root cause
Outlier detection uses a non-robust statistic (weighted mean). A single anomalous value with
sufficient weight shifts the mean toward itself, so it is *within* tolerance of the mean while
the honest cluster falls *outside* tolerance. The filter therefore removes the honest sources
and keeps the anomaly, amplifying rather than rejecting it. A robust design compares to the
**median** (as the comment intends), which is insensitive to a minority of extreme values.

## Proof of Concept (runnable Move tests — both pass)
1. `bucket_oracle/tests/adversarial_outlier_tests.move :: test_outlier_filter_amplifies_anomaly`
   - Sources: HonestA=1.0 (w1), HonestB=1.0 (w1), Rogue=2.0 (w10); tolerance 10%.
   - `aggregate()` returns **2.0** (the rogue), not 1.0. The honest sources were removed.
   - Even worse than no filtering: the plain weighted mean would be 1.833; the filter pushed it to 2.0.

2. `bucket_cdp/tests/adversarial_oracle_cdp_tests.move :: test_oracle_manipulation_enables_undercollateralized_borrow`
   - Attacker deposits 1,000 SUI (true value $1,000 at price 1.0); MCR = 110%.
   - True max borrow ≈ 909 USDB. Using the **flawed aggregate (2.0)**, the attacker borrows **1,800 USDB** and it succeeds.
   - `position_is_healthy(attacker, true_price=1.0)` then returns **false** → the position is under-collateralized.
   - The PoC then reads the on-chain position via `get_position_data` and asserts the loss **explicitly**:
     `debt_amount (1,800 USDB) − coll_value_at_true_price (1,000 USDB) = 800 USDB` of unbacked
     bad debt (`assert bad_debt >= 700 USDB`). This is real minted USDB liability, not free/test assets —
     the collateral was funded and the debt is a genuine protocol obligation; only the *price used to
     size it* was wrong. A full liquidation at the true price recovers ~1,000 USDB and leaves ~800 USDB
     minted with nothing behind it → direct loss of funds.

Run:
```
sui move test adversarial_outlier      # in bucket_oracle
sui move test adversarial_oracle_cdp   # in bucket_cdp
```

## Impact & severity (honest assessment)
- The broken mechanism is a **safety-critical oracle defense** whose entire purpose is to
  neutralize an anomalous source price — exactly the threat the protocol acknowledges by having
  outlier detection. It fails and backfires.
- **Precondition:** a *weighted* source must report an anomalous price. An external attacker
  cannot forge a source witness, so this requires a source whose feed is manipulable, a
  compromised source, or extreme volatility — AND that source must hold a large weight share
  for the anomaly to *dominate* (with balanced weights, divergence instead causes the
  aggregation to abort — a fail-safe/liveness issue rather than a wrong price).
- Realistic rating: **Medium**, escalating to **High** if the deployed aggregator assigns a
  dominant weight to any single source whose price feed is manipulable (verify on-chain weights).

## Recommended fix
Compare each price to the **weighted median** (or an iterative/robust estimator), matching the
L73 comment, so a minority of extreme values cannot skew the reference used to detect them.
Additionally, require a minimum count of *surviving* sources after filtering.

## Notes for the reporter
- Before submitting, check the live `PriceAggregator` weight configuration on a Sui explorer.
  If a single source has a dominant weight, argue **High** with the on-chain config as evidence.
  Otherwise submit as **Medium** (logic-vs-description + defense-in-depth failure) with the two PoCs.
