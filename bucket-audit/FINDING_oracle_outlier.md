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

## Proof of Concept (runnable Move tests — all pass)
1. `bucket_oracle/tests/adversarial_outlier_tests.move :: test_outlier_filter_amplifies_anomaly`
   - Sources: HonestA=1.0 (w1), HonestB=1.0 (w1), Rogue=2.0 (w10); tolerance 10%.
   - `aggregate()` returns **2.0** (the rogue), not 1.0. The honest sources were removed.
   - Even worse than no filtering: the plain weighted mean would be 1.833; the filter pushed it to 2.0.

1b. Boundary characterization (same file), proving the exact conditions above:
   - `test_weight_boundary_around_half` — at δ=22%, sweeping the dominant weight 49% / 50% / 51%
     yields result **1.00** (deviator correctly rejected) / **1.11** (tempered mean) / **1.22**
     (honest rejected — the flip), pinning the boundary at exactly 50%.
   - `test_deviation_below_window_yields_mean` (f=60%, δ=10%) → **1.06** (mean, no flip).
   - `test_deviation_inside_window_full_flip` (f=60%, δ=25%) → **1.25** (deviated price alone).
   - `test_deviation_above_window_aborts` (f=60%, δ=40%) → **abort** (liveness, not wrong price).

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

## Exploitability window (derived from the code, empirically confirmed)
Let the honest cluster price be `1.0`, a single source hold weight fraction `f` of the total,
and report a deviated price `1 + δ`. The filter compares each price to the weighted mean
`m = 1 + f·δ` and removes any source whose relative distance from `m` exceeds `tol`. Then:

- Honest sources are removed iff `f·δ / (1 + f·δ) > tol`  ⇒ `δ > δ_min = tol / (f·(1 − tol))`
- The deviating source is *kept* iff `(1 − f)·δ / (1 + f·δ) ≤ tol`  ⇒ `δ ≤ δ_max = tol / ((1 − f) − f·tol)`

A non-empty "flip" window `(δ_min, δ_max]` exists **iff `f > 50%`** (only then is the deviating
source closer to the mean than the honest cluster). Behavior by regime (proven in the boundary tests):

| Regime | Outcome |
|---|---|
| `f ≤ 50%` | Deviating source is the farther one → correctly rejected (no flip at any δ). |
| `f > 50%`, `δ ≤ δ_min` | All sources kept → result is the mildly skewed mean `1 + f·δ`. |
| `f > 50%`, `δ_min < δ ≤ δ_max` | **Honest sources removed, deviated price stands alone → maximal price error.** |
| `f > 50%`, `δ > δ_max` | Deviating source also removed → aggregation aborts (liveness, not wrong price). |

Worked example (`f = 60%`, `tol = 10%`): the danger window is **18.52% < δ ≤ 29.41%**.

## Impact & severity (honest assessment)
- The broken mechanism is a **safety-critical oracle defense** whose entire purpose is to
  neutralize an anomalous source price — exactly the threat the protocol acknowledges by having
  outlier detection. It fails and backfires.
- **No external-attacker exploit exists from the code alone:** `result::new` is `public(package)`
  and `aggregate()` requires holding every registered source witness, so a `PriceResult` cannot be
  forged and unregistered sources are filtered. The wrong price therefore arises from a *legitimate*
  dominant source deviating (manipulable/laggy feed or volatility), **not** from attacker input.
- **But that does not make it low-impact:** once the aggregate is wrong, *any ordinary user* borrows
  at the protocol's wrong price → under-collateralized debt / bad debt. No attacker control is needed
  for the loss; there is also no TWAP or staleness guard (`PriceResult` carries no timestamp), so the
  skewed price is consumed raw. This is a wrong-price-during-normal-operation issue, **not** a
  front-run-only one.
- **Honest rating:**
  - **Medium — confirmed from the code + non-dominant configs** (logic differs from the documented
    "median" design; runnable PoCs; conditional loss path).
  - **High — technically proven, conditional on production config:** realized if a single price source
    holds **> 50%** of the aggregator weight and its deviation lands in the derived window. The
    "primary feed + lighter backups" topology (primary > 50%) is a common oracle design, so this is a
    realistic configuration, not a contrived one.
- **The decisive triage question:** *what are the actual production weights of the deployed
  `PriceAggregator`s?* This is deployment state we cannot read from the source repo; the logic flaw
  and its impact stand regardless.

## Recommended fix
Compare each price to the **weighted median** (or an iterative/robust estimator), matching the
L73 comment, so a minority of extreme values cannot skew the reference used to detect them.
Additionally, require a minimum count of *surviving* sources after filtering.

## Notes for the reporter
- Before submitting, check the live `PriceAggregator` weight configuration on a Sui explorer.
  If a single source has a dominant weight, argue **High** with the on-chain config as evidence.
  Otherwise submit as **Medium** (logic-vs-description + defense-in-depth failure) with the two PoCs.
