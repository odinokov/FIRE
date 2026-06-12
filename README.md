# Retirement Principal Calculator

A single-file Monte Carlo retirement calculator that answers one question:

> Standing at retirement age, how much money do I need invested today so that, with at least probability `target`, my portfolio survives until I die?

There is no accumulation phase, no monthly-contribution planner, no advice. Just: enter your numbers, get one principal figure plus its equivalent in VOO shares.

## Running it

Use the hosted version at <https://odinokov.github.io/FIRE>, or double-click `index.html` to run it locally. It opens in your browser and runs entirely client-side. Nothing is uploaded; no API keys; no analytics; no external network requests; no build step. The math runs in pure JavaScript using typed arrays — 10,000 simulated retirements complete in roughly 150–300 ms on commodity hardware.

## Inputs explained

The calculator groups inputs into four sections.

### Spending and horizon

**Net monthly spending ($, today's purchasing power, after-tax).** The amount you'd need today, in today's dollars, to live the way you want in retirement. After tax. The model inflates this through retirement using stochastic CPI, so don't pre-inflate it.

**Retirement age.** The year you stop working and start drawing down. The first withdrawal happens at this age.

**Life expectancy.** The horizon. The portfolio must survive through (but not necessarily beyond) this age. For early retirees, plan generously — see the note on the 4% rule below.

### Markets and inflation

**Mean annual return (arithmetic) and SD.** Defaults are 10.33% / 15.2%, anchored on the recent 30-year VOO experience. If you want to model long-run S&P 500 history including the Depression and 1970s, raise SD to ~19.7% — your principal target will jump roughly 15–25%.

**Mean CPI inflation and SD.** Defaults 2.5% / 1.0% reflect the post-1990 disinflationary regime. The model uses an AR(1) process with persistence φ=0.6, so high-inflation years cluster realistically rather than being independent draws.

**Current VOO share price ($).** Used only to translate the principal into a share count. The default $663 is approximate as of mid-2026; edit it to match the current quote (Vanguard, Yahoo Finance, your broker).

### Health insurance

**Health-premium inflation.** Default 5.0% — a midpoint between the BLS historical figure (~3.4%) and forward-looking actuarial estimates from Milliman (4.7%) and HealthView Services (5.8%).

**Annual premium ($, today).** Today's annual premium for whatever coverage bridges you to Medicare and supplements it after. The model grosses this up for tax (assumes you pay it out of taxable withdrawals) and inflates it deterministically.

### Simulation settings

**Effective tax rate on withdrawals.** A flat lifetime rate applied to all portfolio withdrawals. The model grosses up your spending need: if you want $5,000/month net at a 20% rate, the portfolio actually withdraws $6,250/month.

**Success probability target.** The minimum probability that your portfolio survives the full horizon. 95% is conventional. For early retirees with 50-year horizons, the Trinity Study suggests using a target equivalent to a 3.5% safe withdrawal rate — try 95–97% and check the implied SWR.

## What the output means

```
Required Principal at Retirement
$2,280,000
at age 40 · 50 years horizon
success 95.0% (95% CI 94.6–95.4%) · implied SWR 2.89%

VOO Equivalent
3,439 shares @ $663.00
```

The **success** line reports the achieved survival fraction at the rounded principal, with a Wilson 95% confidence interval reflecting Monte Carlo noise across the 10,000 paths. The **implied SWR** is your first-year gross withdrawal divided by the principal — see "Sanity-checking your result" below. Exact figures vary slightly between runs (each Calculate draws fresh random paths).

The principal is in **nominal dollars at retirement** — that is, the amount you'd need on the day you retire, not the amount you'd need today. With 10 years between now and retirement at 2.5% inflation, today's $2M and retirement-day $2.5M buy the same lifestyle.

The VOO conversion is a quick scale check, not a portfolio recommendation. The model assumes a single asset with the return profile you specified; using VOO as the proxy is reasonable for a 100% S&P 500 portfolio but ignores diversification, bond allocations, international exposure, and so on.

---

## How the math works

The calculator runs **10,000 simulated retirements** using your assumptions, then uses **bisection** to find the smallest starting principal at which the fraction of surviving paths meets your target. Five steps.

### Step 1 — Pre-generate stochastic returns

For each of the 10,000 paths, draw `yrs` independent annual returns from `N(μ, σ²)` and floor at −95% (a near-impossible guard against pathological draws).

The implementation uses **antithetic pairing** for variance reduction: half the paths use `μ + σ·z`, the other half use `μ − σ·z` for the same `z`. This halves Monte Carlo noise for free.

Each run draws a fresh set of random paths, so repeated runs with the same inputs differ by a few thousand dollars of Monte Carlo noise — the confidence interval on the success line quantifies it. (The simulation core accepts an optional seed for reproducibility; the test harness uses it.)

### Step 2 — Pre-generate stochastic inflation

CPI is modeled as an AR(1) process:

```
π_t = (1 − φ)·μ_π + φ·π_{t−1} + ε_t,    ε_t ~ N(0, σ_ε²)
```

with `φ = 0.6` and `σ_ε = σ_π · √(1 − φ²)` chosen so the **unconditional** SD equals your `cpi_sd` input. Year 1 is initialized from the stationary distribution `N(μ_π, σ_π²)`. The cumulative price index after t years is `∏ₖ (1 + π_k)`, computed in log-space for numerical stability.

Without this autocorrelation term, the simulated inflation would be IID white noise — wildly understating the realistic risk of multi-year above-target periods like the late 1970s.

### Step 3 — Pre-compute annual withdrawals

For each path and each retirement year `t = 0..yrs-1`, the gross-of-tax withdrawal is:

```
W_t = (12·monthly_target / (1−tax)) · CPI_index_t      ←  general spending
    + (annual_health_premium / (1−tax)) · (1 + h)^t     ←  health premium
```

The first withdrawal happens immediately at retirement age, so `CPI_index_0 = 1` and the first health-premium factor is also 1. Health premiums grow deterministically by `h` per year after that (we don't model premium volatility separately — see Limitations).

### Step 4 — Define a "did it survive?" function

Given a starting principal `P`:

```
balance = P  (for each path)
for year t = 0..yrs-1:
    balance = balance − W_t
    if balance < 0: this path failed
    balance = balance · (1 + return_t)
return fraction of paths that survived all years
```

Because the same return matrix and CPI matrix are used for every call (Common Random Numbers), this function is monotone non-decreasing in `P`. That makes bisection possible.

### Step 5 — Bisect on principal

We seek the smallest `P*` such that `success_rate(P*) ≥ target`.

1. Initial bracket: `lo = 0`, `hi = 25 × annual_gross_need` (the inverse-4%-rule estimate).
2. Double `hi` until `success_rate(hi) ≥ target`. Almost never needed — the initial bracket is generous. If even 30 doublings can't reach the target (pathological assumptions, e.g. a deeply negative mean return), the calculator reports an error instead of a misleading number.
3. Bisect: while `hi − lo > $1000`, set `mid = (hi+lo)/2` and shrink the interval based on `success_rate(mid)`.

Final principal is rounded up to the nearest $1000. Total runtime: ~150 ms because each bisection iteration just re-walks the precomputed return/withdrawal matrices.

---

## Where the defaults come from

Every numerical default is anchored on a published source. Citations are kept short on purpose.

### Equity returns: mean ≈ 10.33%, SD = 15.2%

Anchored on the recent 30-year VOO-equivalent experience. From [Lazy Portfolio ETF](http://www.lazyportfolioetf.com/etf/vanguard-sp-500-voo/), citing data through April 2026:

> in the previous 30 Years, the Vanguard S&P 500 (VOO) ETF obtained a 10.24% compound annual return, with a 15.31% standard deviation

Note that the cited 10.24% is a **compound (geometric)** return, while the model's input is an **arithmetic** mean. With σ ≈ 15.2%, a 10.24% CAGR corresponds to an arithmetic mean of roughly 10.24% + σ²/2 ≈ 11.4%. The 10.33% default is deliberately below that — an extra margin of conservatism on top of using the recent-era SD.

For the long-run perspective (S&P 500 since 1928), [Marshall & Stevens](https://marshall-stevens.com/insights-center/the-sp-500-returns-a-historical-perspective-part-2/) reports:

> The standard deviation of the S&P returns since 1928 was 19.7%

**The SD default is the conservative recent-era figure, not the long-run figure.** If you want your model to include the Depression, two oil shocks, and 2008 in roughly historical proportions, raise SD to 19.7%. Required principal will jump 15–25%.

### Inflation: mean ≈ 2.5%, SD ≈ 1.0%

Reflects the post-1990 Fed-anchored regime. From [InflationData.com](https://inflationdata.com/articles/historical-u-s-inflation-and-cpi-index/):

> The average annual inflation from 1990 through the end of 2018 was 2.46%

The 1.0% SD is consistent with realized post-1990 volatility. To capture 1970s-style inflation tail risk, raise SD to 2.5–3%.

### CPI persistence: φ = 0.6

The [European Central Bank Working Paper No. 370](https://www.ecb.europa.eu/pub/pdf/scpwps/ecbwp370.pdf) on inflation persistence reports an AR(1) coefficient of:

> no variation in persistence over time; it goes from 0.59 to 0.58 after 1991

So 0.6 sits squarely in the empirically observed range across countries and regimes (typical estimates: 0.5–0.9).

### Health-insurance inflation: 5.0%

A midpoint between historical and forward-looking estimates. From the [BLS Monthly Labor Review study on CPI total-premium inflation](https://www.bls.gov/opub/mlr/2024/article/measuring-total-premium-inflation-for-health-insurance-in-the-cpi.htm):

> From December 2005 to December 2022, the implied total-premium index increased by 77.9 percent, an average annual increase of 3.4 percent

But forward-looking actuarial estimates are materially higher. From [Milliman's 2025 Retiree Health Cost Index](https://www.milliman.com/en/insight/retiree-health-cost-index-2025):

> Milliman estimates a future medical trend of 4.7% annually over the next 25 years

And from [HealthView Services' 2026 report](https://www.napa-net.org/news/2026/2/healthcare-inflation-could-eclipse-social-security-in-retirement/):

> a projected long-term inflation rate of 5.8%

The 5.0% default is the midpoint. Users who want only the BLS historical pace can revert to 3.4–4.0%.

### Cross-check against the Trinity Study (4% rule)

From [Retirement Researcher](https://retirementresearcher.com/safe-withdrawal-rates-for-retirement-and-the-trinity-study/):

> with 30-year horizons and a 50/50 portfolio, the success rate is 100% with a 4% initial withdrawal rate

But the original Trinity Study only covers 30 years. From [The Poor Swiss's updated Trinity simulation](https://thepoorswiss.com/updated-trinity-study/):

> If you increase the simulation time to more than 30 years, a 4% withdrawal rate is no longer safe

For 50-year horizons the recommended rate drops to about 3.5%. This is a direct sanity check for our calculator: with $5,000/month spending, $6,000/year health, retirement age 40, life expectancy 90 (50 years), 95% target, our model produces a principal of $2.28M against a $66k first-year gross need — an implied SWR of 2.89%, or about `34.5×` annual gross need. That's somewhat more conservative than the 3.5% guideline, mostly because the health premium inflates at 5% per year rather than at CPI.

### Validation summary

| Parameter | Default | Source | Verdict |
|---|---|---|---|
| Return mean (10.33%) | Recent VOO-era | LazyPortfolioETF: 30-yr CAGR 10.24% | Defensible |
| Return SD (15.2%) | Recent VOO-era | LazyPortfolioETF: 30-yr SD 15.31% | Conservative-leaning; long-run is ~19.7% |
| CPI mean (2.5%) | Post-1990 | InflationData: 1990–2018 was 2.46% | Validated |
| CPI SD (1.0%) | Post-1990 era | Realized post-1990 ≈ 1.0–1.5% | Defensible |
| CPI persistence φ (0.6) | Mid-range AR(1) | ECB WP No. 370: empirical AR(1) ~0.58–0.59 | Validated |
| Health-care inflation (5.0%) | Forward-looking midpoint | BLS 3.4%, Milliman 4.7%, HealthView 5.8% | Validated |
| 4% / 3.5% SWR sanity check | Trinity Study | 100% success at 30 yrs / weakens past 30 | Default output is 2.9% — conservative side of the band, driven by 5% health inflation |

---

## Sanity-checking your result

Your annual gross spending need divided by your principal is your **implied safe withdrawal rate** — both versions display it directly beneath the result.

- **2.5–3.5%** → conservative; appropriate for 40+ year horizons
- **3.5–4.0%** → standard 30-year-retirement territory (the famous "4% rule")
- **5%+** → aggressive; the Trinity Study found 5% had ~68% success at 30 years, lower at longer horizons

If your implied SWR is far outside these bands, double-check your inputs — especially that you entered net (after-tax) spending and that your horizon matches your retirement age and life expectancy.

## Known limitations

| Limitation | Effect | When it matters |
|---|---|---|
| Returns are IID Normal | Underweights fat tails, no momentum, no mean reversion | Long horizons; recent equity data shows kurtosis ~3.5 |
| Returns and inflation are independent | Empirically there's mild negative correlation between equity returns and inflation shocks | 1970s-style stagflation scenarios |
| Health inflation is deterministic | Real health costs have meaningful volatility | Late retirement years where premiums dominate |
| Tax rate is a flat lifelong constant | No bracket logic, no Roth/traditional split, no Social Security taxation | High earners, complex tax situations |
| No sequence-of-returns adjustment beyond what falls out of the MC | Adequate for a model this size | First-decade returns matter disproportionately |
| Spending is constant in real terms | No "smile curve" (high spending early/late, low middle) and no annuity-style adjustment | If you plan dynamic withdrawals |

These are honest simplifications. For each, the calculator's defaults err slightly toward conservatism (overstating principal) rather than optimism — which is the right direction for a planning tool.

## What the calculator is not

It is **not a forecast**. It produces a probability distribution over 10,000 alternative futures, each consistent with your assumptions. You will live exactly one of those futures, and it will not be the median.

It is **not investment advice**. It is a model that takes your assumptions and reports a number. If your assumptions are wrong, the number is wrong. The defaults are anchored on real data but real data is messy.

## License

MIT License

---

**Disclaimer:** Educational model only. Not investment advice. Estimates are stochastic and non-guaranteed. Market returns, inflation, taxes, fees, and health costs all vary in reality. Use at your own risk and consult a qualified advisor before making decisions that depend on this output.
