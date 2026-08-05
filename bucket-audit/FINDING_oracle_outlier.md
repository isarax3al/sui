# Oracle outlier-rejection is mean-based (not median) — anomalous source dominates the aggregate, enabling under-collateralized borrows

## Summary
The README describes the oracle's Outlier Detection as *"Automatic filtering of abnormal prices"*
(and the workflow step *"Filter outliers beyond tolerance"*). The implementation does the
**opposite** under a realistic configuration: `bucket_oracle::aggregator::remove_outliers` compares
every source price to the **weighted mean** of all prices, and because the mean is itself pulled
toward an anomalous price, a source holding a **majority weight share (> 50%)** is **not** filtered —
instead the honest minority is flagged as outliers and removed, and the abnormal price **dominates**
the final aggregate. The safety mechanism amplifies the anomaly it was built to reject. (The code's
own field comment at L73 says the tolerance is a *"deviation from the median price"*, confirming the
intended statistic was the robust median, not the mean.)

Because the aggregated price feeds `bucket_cdp::vault::position_is_healthy` (collateral-ratio
check) and `bucket_psm::pool::check_price`, an inflated aggregate lets a user borrow far more
USDB than their collateral is truly worth → under-collateralized debt / bad debt → loss of
funds for the protocol.

## Scope
- In scope: the defective file is in the audited repo (`bucket_oracle/sources/aggregator.move`),
  not an imported contract. The defect is reproducible from source without touching access control
  or corrupting the oracle object.
- Primary category: **"Attacks on logic (behavior of the code is different from the business
  description)"** — README promises *"Automatic filtering of abnormal prices"*; the code retains the
  abnormal price and discards the honest ones (a code comment even names the intended statistic as
  *median*). Under a majority-weight source this escalates to **"loss of funds"**.
- Not front-run-only, not a DoS report: the harm is a *wrong price accepted during normal operation*.

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

2b. `bucket_cdp/tests/adversarial_oracle_cdp_tests.move :: test_realistic_majority_source_enables_bad_debt`
   — **the High-severity PoC under a realistic production topology.**
   - Oracle config: **Primary 60% + BackupA 20% + BackupB 20%** (a single majority source; the
     canonical "primary feed + backups" design).
   - Primary deviates **+25%** (inside the derived window, so both honest backups are discarded);
     the aggregate resolves to **1.25** — a deviating legitimate feed, not an attacker-forged price.
   - Using the vault's real rules (MCR 110%): 1,000 SUI collateral, borrow **1,100 USDB**
     (impossible at the true price where max ≈ 909, allowed at 1.25 where max ≈ 1,136).
   - `update_position` accepts it because `position_is_healthy` consumes the wrong price.
   - After the price corrects to 1.0, `get_position_data` shows debt 1,100 vs true collateral value
     1,000 → the PoC asserts **≥ 100 USDB unrecoverable bad debt per 1,000 SUI** (`bad_debt >= 90`).

3. `bucket_oracle/tests/adversarial_outlier_tests.move :: test_configuration_accepts_majority_weight_source`
   — proves the > 50% precondition is **officially supported, not contrived**: `set_rule_weight`
   accepts any `u8`, enforces **no per-source cap** and **no honest-majority invariant**, and the
   60/20/20 config both initializes and aggregates through the public API with no abort.

Run:
```
sui move test adversarial_outlier      # in bucket_oracle  (7 tests)
sui move test adversarial_oracle_cdp   # in bucket_cdp     (2 tests)
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

## Secondary guards (traced, not assumed)
In the traced CDP health-check path — `update_position` → `position_is_healthy` → aggregated
`PriceResult` — **no** post-aggregation validation neutralizes an accepted wrong price:
- `PriceResult` carries **no timestamp**; the consumer cannot check data age.
- `position_is_healthy` applies **no TWAP**, no comparison to a previous price, and no
  rate-of-change / circuit-breaker guard.
- Aggregation does **not** fail on the deviation, because the majority-weight source stays close
  to the weighted mean it itself moved.

(Scoped claim: this is what the CDP health-check call path does; it is not a claim that no guard
exists anywhere in the system.)

## Severity assessment
The aggregation defect is reproducible from the source code and does not require bypassing access
control or corrupting the oracle object itself. When a single configured source holds more than 50%
of the total weight, that source shifts the weighted mean toward its own observation; the subsequent
mean-relative outlier filter then rejects the honest minority while retaining the deviating
majority-weight observation. For majority fraction `f`, tolerance `tol`, and relative deviation `δ`,
the complete-flip condition occupies the bounded interval

```
tol / (f·(1 − tol))  <  δ  ≤  tol / ((1 − f) − f·tol)
```

which at `f = 60%`, `tol = 10%` is `18.52% < δ ≤ 29.41%`. The Move tests reproduce every boundary
(49% rejects the deviator; 50% yields an intermediate mean; 51% reverses the filter; below/inside/
above the window give distorted-mean / full-flip / abort).

- **The code-level defect is confirmed independently of production configuration**, and the
  `> 50%` precondition is an **officially supported** state (no per-source cap, no honest-majority
  invariant — proven by `test_configuration_accepts_majority_weight_source`).
- **High — reachable and demonstrated** if any production asset uses a single source with `> 50%`
  of the configured weight: the aggregated result is consumed by the CDP health check with no
  timestamp and, in the traced path, no TWAP/freshness/rate-of-change validation. Depending on the
  deviation direction this permits **excess debt issuance** (shown: ≥ 100 USDB bad debt per 1,000
  SUI at a 25% deviation) or **incorrect liquidation**, and creates unrecoverable protocol bad debt.
- **Medium — the provable floor** if all deployed configurations enforce that no single source
  exceeds 50% of total weight: the defective aggregation and the availability (abort) failure remain,
  but the complete-flip is unreachable.
- **The decisive triage question:** *do any deployed `PriceAggregator`s assign a single source
  > 50% of the total weight?* This is deployment state that cannot be read from the source repo.

## Recommended fix
Compare each price to the **weighted median** (or an iterative/robust estimator), matching the
L73 comment, so a minority of extreme values cannot skew the reference used to detect them.
Additionally: cap any single source's weight below 50%, and require a minimum count of *surviving*
independent sources after filtering.

## Notes for the reporter
- The finding stands on the source code alone (logic-vs-description + the runnable PoCs). The only
  lever between Medium and High is the **deployed source weights**.
- If you can read the live `PriceAggregator` weights on a Sui explorer and any single source is
  `> 50%`, attach that as on-chain evidence and argue **High** — the 60/20/20 PoC then matches the
  real config rather than a hypothetical one.
- Do **not** overstate: frame High as *conditional on / demonstrated for* a majority-weight config,
  with Medium as the guaranteed floor. This matches the evidence and survives triage scrutiny.
