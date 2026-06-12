library(shiny)

# =====================================================================
# Retirement Principal Calculator — Monte Carlo decumulation
#
# Question: standing at retirement age, how much principal do I need so
# that, with probability >= target, the portfolio survives until
# death_age?
#
# All numerical defaults validated against external sources; see the
# accompanying RETIREMENT_CALCULATOR_LOGIC.md for citations.
# Note: the default health_insurance_cpi was raised from 0.039 to 0.050
# based on Milliman (4.7%) and HealthView Services (5.8%) projections,
# which are higher than the BLS backward-looking 3.4% historical figure.
# =====================================================================

required_principal <- function(
    monthly_target,
    retire_age,
    death_age,
    nominal_return,
    return_sd,
    cpi,
    cpi_sd,
    health_insurance_cpi,
    annual_health_insurance_premium,
    tax_rate,
    sims      = 10000L,
    target    = 0.95,
    precision = 1000,
    rng       = NULL
) {
  if (!all(is.finite(c(monthly_target, retire_age, death_age, nominal_return,
                       return_sd, cpi, cpi_sd, health_insurance_cpi,
                       annual_health_insurance_premium, tax_rate, target))))
    stop("All inputs must be filled in with valid numbers.")
  if (death_age <= retire_age)       stop("Life expectancy must exceed retirement age.")
  if (tax_rate < 0 || tax_rate >= 1) stop("tax_rate must be in [0, 1)")
  if (target <= 0 || target >= 1)    stop("target must be in (0, 1)")
  if (any(c(monthly_target, return_sd, cpi_sd, health_insurance_cpi,
            annual_health_insurance_premium) < 0))
    stop("Negative inputs not allowed")

  yrs <- as.integer(death_age - retire_age)
  if (!is.null(rng)) set.seed(rng)

  # Returns: N(mu, sigma) with antithetic pairing
  half <- ceiling(sims / 2)
  z_h  <- matrix(rnorm(half * yrs), half, yrs)
  z    <- rbind(z_h, -z_h)[seq_len(sims), , drop = FALSE]
  rets <- pmax(nominal_return + return_sd * z, -0.95)

  # CPI: AR(1), phi = 0.6 (ECB WP No. 370 reports empirical AR(1) ~0.58–0.59)
  phi       <- 0.6
  sigma_eps <- cpi_sd * sqrt(max(1e-12, 1 - phi^2))
  cpi_series <- matrix(NA_real_, sims, yrs)
  # Floor at -50% inside the recursion (matching the JS implementation),
  # so the floored value feeds the next year's AR(1) step.
  cpi_series[, 1] <- pmax(rnorm(sims, mean = cpi, sd = cpi_sd), -0.5)  # stationary init
  if (yrs >= 2) {
    eps <- matrix(rnorm(sims * (yrs - 1), 0, sigma_eps), sims, yrs - 1)
    for (t in 2:yrs) {
      cpi_series[, t] <- pmax(cpi * (1 - phi) +
                              phi * cpi_series[, t - 1] +
                              eps[, t - 1], -0.5)
    }
  }
  cpi_index  <- exp(t(apply(log1p(cpi_series), 1, cumsum)))

  # Annual withdrawals (gross of tax)
  gross_annual_general <- 12 * monthly_target / (1 - tax_rate)
  gross_annual_health  <- annual_health_insurance_premium / (1 - tax_rate)
  gross_need <- gross_annual_general + gross_annual_health
  if (gross_need == 0) {
    return(list(
      principal         = 0,
      gross_annual_need = 0,
      success_percent   = 100,
      success_ci        = c(100, 100),
      retire_age        = retire_age
    ))
  }

  withdrawal_cpi_index <- cbind(1, cpi_index[, seq_len(max(yrs - 1, 0)), drop = FALSE])
  w_gen      <- gross_annual_general * withdrawal_cpi_index
  health_fac <- (1 + health_insurance_cpi)^(0:(yrs - 1))
  w_hi       <- outer(rep(gross_annual_health, sims), health_fac)
  wd         <- w_gen + w_hi

  success_rate <- function(p) {
    bal   <- rep(p, sims)
    alive <- rep(TRUE, sims)
    for (yr in seq_len(yrs)) {
      if (!any(alive)) break
      idx <- which(alive)
      bal[idx] <- bal[idx] - wd[cbind(idx, yr)]
      alive[idx] <- bal[idx] >= 0
      idx <- which(alive)
      bal[idx] <- bal[idx] * (1 + rets[cbind(idx, yr)])
    }
    mean(alive)
  }

  # Bisect on principal (common random numbers across calls)
  lo <- 0
  hi <- max(1, gross_need / 0.04)
  tries <- 30
  while (success_rate(hi) < target) {
    tries <- tries - 1
    if (tries == 0)
      stop("Success target is unattainable under these assumptions — ",
           "lower the target or revisit the return and inflation inputs.")
    lo <- hi  # a failing hi is a valid lower bound (success is monotone in P)
    hi <- hi * 2
  }
  while ((hi - lo) > precision) {
    mid <- (hi + lo) / 2
    if (success_rate(mid) >= target) hi <- mid else lo <- mid
  }
  principal <- ceiling(hi / precision) * precision

  p_hat  <- success_rate(principal)
  z975   <- 1.96
  denom  <- 1 + z975^2 / sims
  center <- (p_hat + z975^2 / (2 * sims)) / denom
  half_w <- (z975 * sqrt(p_hat * (1 - p_hat) / sims +
                         z975^2 / (4 * sims^2))) / denom
  ci <- pmin(pmax(c(center - half_w, center + half_w), 0), 1)

  list(
    principal         = principal,
    gross_annual_need = gross_need,
    success_percent   = round(p_hat * 100, 1),
    success_ci        = round(ci * 100, 1),
    retire_age        = retire_age
  )
}

# =====================================================================
# UI
# =====================================================================
ui <- fluidPage(
  titlePanel("Retirement Principal Calculator"),
  h4("Ever wondered how many $VOO shares it takes to quit the day job at 40?"),
  h4("Plug in your own numbers here and see where you stand!"),
  sidebarLayout(
    sidebarPanel(
      h4("Spending & Age"),
      numericInput("monthly_target",
                   "Net monthly spending ($, today's purchasing power, after-tax):",
                   5000, 0, 100000, 100),
      numericInput("retire_age", "Retirement age:",
                   40,   19, 105,  1),
      numericInput("death_age",  "Life expectancy:",
                   90,   20, 105,  1),

      hr(), h4("S&P 500 / market assumptions"),
      numericInput("nom_return", "Mean annual return (arithmetic):",
                   0.1033, 0, 1, 0.001),
      numericInput("return_sd",  "Annual return SD:",
                   0.152,  0, 1, 0.001),
      numericInput("cpi",        "Mean CPI inflation:",
                   0.025,  0, 1, 0.001),
      numericInput("cpi_sd",     "CPI SD:",
                   0.010,  0, 1, 0.001),
      numericInput("voo_price",  "Current VOO share price ($):",
                   663,    0.01, 100000, 0.01),

      hr(), h4("Health insurance"),
      # Default raised from 0.039 to 0.050 based on Milliman 4.7% /
      # HealthView 5.8% forward-looking projections.
      numericInput("health_cpi",         "Health-premium inflation:",
                   0.050, 0, 0.20,   0.001),
      numericInput("annual_health_prem", "Annual premium ($, today):",
                   6000,  0, 100000, 100),

      hr(), h4("Simulation settings"),
      sliderInput("tax_rate", "Effective tax rate on withdrawals:",
                  min = 0, max = 0.60, value = 0.00, step = 0.001),
      sliderInput("target",   "Success probability target:",
                  min = 0.68, max = 0.995, value = 0.95, step = 0.005),
      actionButton("run_sim", "Calculate", class = "btn-primary")
    ),
    mainPanel(
      uiOutput("result_box"),
      hr(),
      tags$p(tags$strong("Conventions"), style = "margin-bottom:4px;"),
      tags$p(
        "Spending is entered in today's purchasing power, after tax. ",
        "The model inflates it through retirement using stochastic CPI. ",
        "The health-insurance premium is grossed up for tax (it assumes ",
        "you pay it from taxable withdrawals).",
        style = "font-size:12px;color:#6c757d;line-height:1.4;margin:0 0 6px 0;"
      ),
      tags$p(tags$strong("Disclaimer"), style = "margin-bottom:4px;"),
      tags$p(
        "Educational model only. Not investment advice. Estimates are ",
        "stochastic and non-guaranteed. Market returns, inflation, taxes, ",
        "fees, and health costs all vary in reality.",
        style = "font-size:12px;color:#6c757d;line-height:1.4;margin:0;"
      )
    )
  )
)

# =====================================================================
# Server
# =====================================================================
server <- function(input, output, session) {
  sim_res <- eventReactive(input$run_sim, {
    # Domain validation lives in required_principal(); only the UI-only
    # voo_price (not a model argument) is checked here.
    validate(need(input$voo_price > 0, "VOO share price must be positive."))

    res <- required_principal(
      monthly_target                  = input$monthly_target,
      retire_age                      = input$retire_age,
      death_age                       = input$death_age,
      nominal_return                  = input$nom_return,
      return_sd                       = input$return_sd,
      cpi                             = input$cpi,
      cpi_sd                          = input$cpi_sd,
      health_insurance_cpi            = input$health_cpi,
      annual_health_insurance_premium = input$annual_health_prem,
      tax_rate                        = input$tax_rate,
      sims                            = 10000L,
      target                          = input$target,
      precision                       = 1000
    )
    res$voo_price <- input$voo_price
    res
  })

  output$result_box <- renderUI({
    validate(need(input$run_sim > 0,
                  "Enter your numbers, then press Calculate."))
    res <- sim_res()
    fmt_int <- function(x) formatC(x, format = "f", digits = 0,
                                   big.mark = ",", decimal.mark = ".")
    fmt_2   <- function(x) formatC(x, format = "f", digits = 2,
                                   big.mark = ",", decimal.mark = ".")

    tags$div(
      style = "background:#f8f9fa; border:1px solid #dee2e6;
               border-radius:5px; padding:15px;",

      tags$h4("Required principal at retirement", style = "margin-top:0;"),
      tags$p(
        tags$strong(paste0("$", fmt_int(res$principal))),
        paste0(" by age ", res$retire_age),
        style = "font-size:22px;color:#007bff;margin:0;"
      ),
      tags$p(
        sprintf("≈ %s VOO shares at $%s / share",
                fmt_int(res$principal / res$voo_price),
                fmt_2(res$voo_price)),
        style = "font-size:14px;color:#343a40;margin:2px 0 0 0;"
      ),
      if (res$principal > 0) tags$p(
        sprintf("Implied SWR: %.2f%% of principal per year (gross)",
                100 * res$gross_annual_need / res$principal),
        style = "font-size:12px;color:#343a40;margin:2px 0 0 0;"
      ),
      tags$p(
        sprintf("Success probability: %.1f%% (95%% MC CI: %.1f%%–%.1f%%)",
                res$success_percent,
                res$success_ci[1], res$success_ci[2]),
        style = "font-size:11px;color:#6c757d;margin:4px 0 0 0;"
      )
    )
  })
}

shinyApp(ui, server)
