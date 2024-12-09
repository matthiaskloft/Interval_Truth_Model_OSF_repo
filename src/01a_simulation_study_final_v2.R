#' ---
#' title: "Interval Truth Model - Simulation Study for the Main Model"
#' author: "Matthias Kloft & Björn Siepe"
#' output:
#'   html_document:
#'     toc: yes
#'     toc_float: yes
#'     collapsed: no
#'     smooth_scroll: yes
#'   pdf_document:
#'     toc: yes
#' ---
#' 
#' # Preparation
#' This script contains a simulation study for the Interval Truth Model. 
#' 
## ----load-pkgs------------------------------------------------------------
packages <- c(
  "tidyverse",
  "SimDesign",
  "rstan",
  "here",
  "posterior",
  "bayesplot",
  "psych"
)

if (!require("pacman")) install.packages("pacman")
pacman::p_load(packages, update = F, character.only = T)

if(!require("cmdstanr")){
  install.packages("cmdstanr", repos = c("https://mc-stan.org/r-packages/", getOption("repos")))
  library(cmdstanr)
}
  

# default chunk options
knitr::opts_chunk$set(
  fig.height = 7,
  fig.width = 10,
  include = TRUE,
  message = FALSE,
  warning = FALSE
)
source(here("src", "00_functions.R"))

#' 
#' 
#' 
#' # Generation
#' 
#' ## Data-Generating Processes
#' We vary the number of items and respondents:
## ----sim-dgp--------------------------------------------------------------
n_respondents <- c(10, 50, 100, 200)
n_items <- c(5, 10, 20, 40)

# Create design
df_design <- SimDesign::createDesign(
  n_respondents = n_respondents,
  n_items = n_items
)

#' 
#' 
#' ## Fixed Simulation Parameters
#' 
#' ### Ellerby
#' - sigma person
#' 
#' ### Verbal Quantifiers
## ----sim-pars-------------------------------------------------------------
sim_pars <- list(
    # Stan Sampling
    n_chains = 4,
    iter_warmup = 500,
    iter_sampling = 1000,
    link = 1 # "ilr"
)

#' 
#' 
#' ## Pre-Compile Model
#' 
## ----stan-compile---------------------------------------------------------
# Define model name
model_name <- "itm_simulation_v2_beta"

# Compile model
stan_model <-
  cmdstanr::cmdstan_model(
    stan_file = here("src", "models", paste0(model_name, ".stan")),
    pedantic = TRUE,
    quiet = FALSE
  )
sim_pars$model <- stan_model

#' 
#' 
#' ## Simulating Data
#' 
## ----sim-generate---------------------------------------------------------
sim_generate <- function(condition, fixed_objects = NULL){
  
  #- Preparation
  # obtain fixed params
  SimDesign::Attach(fixed_objects)
  
  #- Generate Data
  sim_data <- generate_itm_data_sim_study(
    n_respondents = condition$n_respondents,
    n_items = condition$n_items, 
    link = ifelse(link == 1, "ilr", "sb")
  )
  
  return(sim_data)
}

#' 
#' 
#' 
#' # Analysis
#' 
## ----sim-analyze----------------------------------------------------------
sim_analyze <- function(condition, dat, fixed_objects = NULL){
  
  #- Preparation
  # obtain fixed params
  SimDesign::Attach(fixed_objects)
  responses <- dat$responses
  true_parameters <- dat$parameters
  
  #- Stan Data
  # Stan data declaration
  I = length(unique(responses$ii))
  J = length(unique(responses$jj))
  N  = nrow(responses)
  ii = responses$ii
  jj = responses$jj
  nn = c(1:N)
  Y_splx = cbind(responses$x_splx_1,
                 responses$x_splx_2,
                 responses$x_splx_3) %>%
    as.matrix()
  
  
  # Stan data list
  stan_data <- list(
    I = I,
    J = J,
    N = N,
    ii = ii,
    jj = jj,
    nn = nn,
    Y_splx = Y_splx,
    link = link # from fixed objects
  )
  
  adapt_delta <- ifelse(I*J <= 1000, .999, .9)
  #- Fit model
  # Run sampler
  fit <- fixed_objects$model$sample(
    data = stan_data,
    chains = n_chains,
    cores = 1,
    iter_warmup = iter_warmup,
    iter_sampling = iter_sampling,
    refresh = 100,
    thin = 1,
    adapt_delta = adapt_delta,
    init = .1
)
  
  # Summary
  pars_names <- 
    c(
      "Tr_loc",
      "Tr_wid",
      "a_loc",
      "b_loc",
      "b_wid",
      "lambda_loc",
      "lambda_wid",
      "E_loc",
      "E_wid",
      "omega"
      #"mu_I",
      #"sigma_I",
      #"mu_J",
      #"sigma_J",
    )
  
  fit_summary <- fit$summary()
  
  # Sampler Diagnostics
  sampler_summary <- fit$sampler_diagnostics(format = "df") %>%
    psych::describe(quant = c(.05, .95)) %>%
    round(2) %>%
    as.data.frame() %>%
    # calculate sum, is relevant for total sum of divergent transitions
    dplyr::mutate(sum = mean * n) %>% 
    dplyr::select(mean, median, min, Q0.05, Q0.95, max, sum, n) 
    
  
  # Convergence, only for main parameters
  convergence_summary <-
    fit$draws(format = "df", variables = pars_names) %>%
    posterior::summarise_draws(.x = ., "rhat", "ess_bulk", "ess_tail") %>%
    remove_missing() %>%
    dplyr::select(-variable)
 
  
  ### Compute simple means of logit transformed values for comparison with ITM
  # compute means in the unbounded space
  simple_means <-
    cbind(jj, 
          simplex_to_bvn(Y_splx, type = ifelse(link == 1, "ilr", "sb"))) %>%
    as.data.frame() %>%
    dplyr::group_by(jj) %>%
    dplyr::summarise(across(everything(), mean, na.rm = TRUE)) %>%
    dplyr::ungroup() %>%
    dplyr::select(-jj) %>%
    rename(simplemean_loc = x_bvn_1, simplemean_wid = x_bvn_2)
  
  
  ### Return list
  return(
    ret = list(
      fit_summary = fit_summary,
      sampler_summary = sampler_summary,
      convergence_summary = convergence_summary,
      true_parameters = true_parameters,
      simple_means = simple_means
    )
  )
}

#' 
#' 
#' 
#' # Summarize
#' 
## ----sim-summarize--------------------------------------------------------
sim_summarize <- function(condition, results, fixed_objects = NULL){
  
  #- Preparation
  # obtain fixed params
  SimDesign::Attach(fixed_objects)
  
  # Prepare output
  ret <- list()
  
  # Function for point estimate comparison
  # Method can either be "model" for the ITM model or "simple" for the simple means
  point_comparison <- function(results = results,
                               method = "model",
                               estimate_name,
                               truth_name,
                               summary,
                               pm) {
    tmp_summary <- sapply(results, function(x) {
    if(method == "model") {  
      x$fit_summary %>%
        dplyr::filter(stringr::str_detect(variable,
            # ensure that it is at the beginning of the string
            # to avoid issues with a_loc and lambda_loc
            paste0("^", estimate_name))) %>%
        dplyr::select(all_of({{summary}}))
    } else if(method == "simple") {
      x$simple_means %>%
        dplyr::select(all_of({{estimate_name}}))
    }})
    # compare against true parameters
    ret <- list()
    for(i in 1:length(tmp_summary)){
      ret[[i]] <- pm(tmp_summary[[i]], results[[i]]$true_parameters[[truth_name]])
    }
    return(ret)
    }
  
  # For bias of point estimates
  fn_abs_bias <- function(est_param,
                          true_param,
                          average = TRUE) {
    if (isTRUE(average)) {
      mean(abs(est_param - true_param), na.rm = TRUE)
    } else {
      abs(est_param - true_param)
    }
  }
  fn_mse <- function(est_param, 
                     true_param, 
                     average = TRUE) {
    if (isTRUE(average)) {
      mean((est_param - true_param) ^ 2, na.rm = TRUE)
    } else {
      mean((est_param - true_param) ^ 2, na.rm = TRUE)
    }
    
  }
  fn_rmse <- function(est_param, 
                      true_param, 
                      average = TRUE) {
    if (isTRUE(average)) {
      mean(sqrt((est_param - true_param) ^ 2), na.rm = TRUE)
    } else {
      sqrt((est_param - true_param) ^ 2)
    }
  }
  
  # create a function that estimates bootstrap mcse given a vector input
  # and a function to calculate the statistic
  bootstrap_mcse <- function(data, n_boot){
    bootstrap_res <- vector("numeric", n_boot)
    for(i in 1:n_boot){
      ind <- sample(1:n_boot, replace = TRUE)
      bootstrap_res[i] <- mean(data[ind], na.rm = TRUE)
    }
      sd(bootstrap_res, na.rm = TRUE)
  }
  
  
  #- All individual PMs
  # Estimate names
  est_names <-
    c(
      "E_loc",
      "E_wid",
      "a_loc",
      "b_loc",
      "b_wid",
      "lambda_loc",
      "lambda_wid",
      "Tr_loc",
      "Tr_wid",
      "omega"
    )
  
  
  # Create a grid of relevant computations
  performance_grid <- expand.grid(
    estimate_name = est_names,
    summary = c("median", "mean"),
    pm = c(
      "fn_abs_bias", 
      "fn_mse" 
      # "fn_rmse"    --> redudant with absolute bias
      ),
    stringsAsFactors = FALSE
  )
  
  performance_grid$truth_name <- performance_grid$estimate_name
  
  
  # Apply function for each row, using the columns of the grid
  # as input arguments
  performance_results <- performance_grid %>%
    mutate(raw = purrr::pmap(., function(estimate_name, method, truth_name, summary, pm) {
      point_comparison(
        results = results,
        estimate_name = estimate_name,
        method = "model",
        truth_name = truth_name,
        summary = summary,
        pm = get(pm)  # evaluate as function
      )
    }))
  
  # Evaluate simple means
  performance_results <- performance_results |> 
    tibble::add_row(
      estimate_name = "simplemean_loc",
      summary = "mean",
      pm = "fn_abs_bias",
      truth_name = "Tr_loc",
      raw = list(point_comparison(results, 
                             estimate_name = "simplemean_loc", 
                             method = "simple",
                             truth_name = "Tr_loc", 
                             summary = "mean", 
                             pm = fn_abs_bias)
    )) |> 
    tibble::add_row(
      estimate_name = "simplemean_wid",
      summary = "mean",
      pm = "fn_abs_bias",
      truth_name = "Tr_wid",
      raw = list(point_comparison(results, 
                             estimate_name = "simplemean_wid", 
                             method = "simple",
                             truth_name = "Tr_wid", 
                             summary = "mean", 
                             pm = fn_abs_bias)
    )) |> 
    tibble::add_row(
      estimate_name = "simplemean_loc",
      summary = "mean",
      pm = "fn_mse",
      truth_name = "Tr_loc",
      raw = list(point_comparison(results, 
                             estimate_name = "simplemean_loc", 
                             method = "simple",
                             truth_name = "Tr_loc", 
                             summary = "mean", 
                             pm = fn_mse)
    )) |>
    tibble::add_row(
      estimate_name = "simplemean_wid",
      summary = "mean",
      pm = "fn_mse",
      truth_name = "Tr_wid",
      raw = list(point_comparison(results, 
                             estimate_name = "simplemean_wid", 
                             method = "simple",
                             truth_name = "Tr_wid", 
                             summary = "mean", 
                             pm = fn_mse)
    ))
  
  
  #- Combined Bias and RMSE of T_loc and T_wid 
  # Goal: evaluate the absolute bias for the combination of loc and wid
  # and the RMSE for the combination of loc and wid
  # method can be either "model" or "simple" 
  interval_comparison <- function(results = results,
                                  method = "model",
                                 summary,
                                 pm,
                                 average = FALSE,
                                 ...) {
    loc_summary <- sapply(results, function(x) {
      
      if (method == "model") {
        x$fit_summary %>%
          dplyr::filter(stringr::str_detect(variable, "Tr_loc")) %>%
          dplyr::select(all_of({{summary}}))
      } else if (method == "simple") {
        x$simple_means %>%
          dplyr::select(all_of(contains("simplemean_loc")))
      }
    })
    wid_summary <- sapply(results, function(x) {
      if (method == "model") {
        x$fit_summary %>%
          dplyr::filter(stringr::str_detect(variable, "Tr_wid")) %>%
          dplyr::select(all_of({{summary}}))
      } else if (method == "simple") {
        x$simple_means %>%
          dplyr::select(all_of(contains("simplemean_wid")))
      }
    })
    
    # compare against true parameters
    ret <- list()
    for(i in 1:length(loc_summary)){
      loc_res <- pm(loc_summary[[i]], 
                     results[[i]]$true_parameters[["Tr_loc"]],
                     ...)
      wid_res <- pm(wid_summary[[i]],
                     results[[i]]$true_parameters[["Tr_wid"]],
                     ...)
      if(isTRUE(average)){
        ret[[i]] <- mean(loc_res + wid_res)
      }
      else{
        ret[[i]] <- loc_res + wid_res
      }
    
    }
    return(ret)
  }
  
  # add performance results for the truth interval
  # RMSE and ABS Bias are redundant here anyway
  performance_results_int <- performance_results %>%
    tibble::add_row(
      estimate_name = "Tr_interval",
      summary = "median",
      pm = "fn_abs_bias",
      truth_name = "Tr_interval",
      raw = list(
        interval_comparison(
          results = results,
          summary = "median",
          pm = fn_abs_bias,
          average = FALSE
        )
      )
    ) |>  
    tibble::add_row(
      estimate_name = "Tr_interval",
      summary = "mean",
      pm = "fn_abs_bias",
      truth_name = "Tr_interval",
      raw = list(
        interval_comparison(
          results = results,
          summary = "mean",
          pm = fn_abs_bias,
          average = FALSE
        )
      )
    ) |> 
    tibble::add_row(
      estimate_name = "Tr_interval",
      summary = "mean",
      pm = "fn_mse",
      truth_name = "Tr_interval",
      raw = list(
        interval_comparison(
          results = results,
          summary = "mean",
          pm = fn_mse,
          average = FALSE
        )
      )
    ) |>
    # add simple means intervals
    tibble::add_row(
      estimate_name = "simplemean_interval",
      summary = "mean",
      pm = "fn_abs_bias",
      truth_name = "Tr_interval",
      raw = list(
        interval_comparison(
          results = results,
          method = "simple",
          summary = "mean",
          pm = fn_abs_bias,
          average = FALSE
        )
      )) |> 
    tibble::add_row(
      estimate_name = "simplemean_interval",
      summary = "mean",
      pm = "fn_mse",
      truth_name = "Tr_interval",
      raw = list(
        interval_comparison(
          results = results,
          method = "simple",
          summary = "mean",
          pm = fn_abs_bias,
          average = FALSE
        )
      ))
  
  
  #- Overall summaries
  # calculate mean and mcse for each performance measure
  # based on the list input in "raw"
  performance_results_int <- performance_results_int %>%
    mutate(
      mean = purrr::map_dbl(raw, function(x) mean(unlist(x), na.rm = TRUE)),
      sd = purrr::map_dbl(raw, function(x) sd(unlist(x), na.rm = TRUE)),
      mcse = purrr::map_dbl(raw, function(x) bootstrap_mcse(unlist(x), 1000))
    )
  
  # Assuming performance_results is your dataframe
  df_pms <- performance_results_int %>%
    select(!c(truth_name, raw)) %>% 
    # gather the numerical columns into a key-value pair
    gather(key = "stat", value = "value", mean, sd, mcse) %>%
    # unite the name columns and the key to form the new names
    unite("new_name", estimate_name, summary, pm, stat, sep = "_") %>%
    # spread the new names and values into a named vector
    spread(key = "new_name", value = "value")

  # convert the dataframe to a named vector
  named_pms <- unlist(df_pms)
  
  
  
  
  
  #- Convergence Diagnostics
  #-- Rhat and ESS
  # Extract convergence diagnostics
  
  # these helpers are a bit stupid, but make the summarise call easier
  prop100 <- function(x) {
    mean(x > 100, na.rm = TRUE)
  }
  prop200 <- function(x) {
    mean(x > 200, na.rm = TRUE)
  }
  prop300 <- function(x) {
    mean(x > 300, na.rm = TRUE)
  }
  prop400 <- function(x) {
    mean(x > 400, na.rm = TRUE)
  }
  
  prop1c1 <- function(x) {
    mean(x < 1.1, na.rm = TRUE)
  }
  prop1c05 <- function(x) {
    mean(x < 1.05, na.rm = TRUE)
  }
  prop1c01 <- function(x) {
    mean(x < 1.01, na.rm = TRUE)
  }
  
  conv_tmp <- as.data.frame(t(sapply(results, function(x) {
    x$convergence_summary %>%
      dplyr::summarise(across(
        c(rhat),
        list(
          mean = mean,
          prop1c1 = prop1c1,
          prop1c05 = prop1c05,
          prop1c01 = prop1c01
        )
      ), across(
        c(ess_bulk, ess_tail),
        list(
          mean = mean,
          prop100 = prop100,
          prop200 = prop200,
          prop300 = prop300,
          prop400 = prop400
        )
      ))
    
  }))) %>%
    dplyr::mutate(across(everything(), as.numeric))
  
  # Calculate mean and mcse for each convergence measure
  ret$mean_conv <- colMeans(conv_tmp)
  names(ret$mean_conv) <- paste0(colnames(conv_tmp), "_mean")
  ret$mcse_conv <- apply(conv_tmp, 2, function(x)
    sd(x, na.rm = TRUE) / sqrt(length(x)))
  # calculate mcse differently for means and proportions
  mcse_conv <- vector("numeric", ncol(conv_tmp))
  # loop through columns
  for (i in seq_along(mcse_conv)) {
    # get data
    x <- conv_tmp[[i]]
    
    # if the column name contains "mean", calculate mcse for means
    if (grepl("mean", colnames(conv_tmp)[i])) {
      mcse_conv[i] <- sd(x, na.rm = TRUE) / sqrt(length(x))
    } else {
      # if the column name contains "prop", calculate mcse for proportions
      mcse_conv[i] <- sqrt(mean(x, na.rm = TRUE) * (1 - mean(x, na.rm = TRUE)) / length(x))
    }
  }
  ret$mcse_conv <- mcse_conv
  names(ret$mcse_conv) <- paste0(colnames(conv_tmp), "_mcse")
  
    #-- Divergent transitions
  # Extract divergent transitions
  div_tmp <- sapply(results, function(x) {
    x$sampler_summary %>%
      tibble::rownames_to_column(var = "stat") %>%
      dplyr::filter(stat == "divergent__") %>%
      dplyr::pull("sum")
  })
  # average number divergent transitions
  ret$mean_divtrans <- mean(div_tmp)
  
  # proportion of repetitions with non-zero divergent transitions
  ret$nonz_divtrans <- sum(div_tmp > 0) / length(div_tmp)
  
  # average number of divergent transitions among repetitions with non-zero divergent transitions
  ret$nonzmean_divtrans <- mean(div_tmp[div_tmp > 0])
  
  names(ret$mean_divtrans) <- "divergent_transitions_mean"
  names(ret$nonz_divtrans) <- "divergent_transitions_nonzero"
  names(ret$nonzmean_divtrans) <- "divergent_transitionsnonzero_mean"
  ret$mcse_divtrans_mean <- sd(div_tmp) / sqrt(length(div_tmp))
  # Standard error of proportion
  ret$mcse_divtrans_nonz <- sqrt(mean(div_tmp >0) * (1 - mean(div_tmp >0)) / length(div_tmp))
  ret$mcse_divtrans_nonzmean <- sd(div_tmp[div_tmp > 0]) / sqrt(length(div_tmp[div_tmp > 0]))
  names(ret$mcse_divtrans_mean) <- "divergent_transitions_mean_mcse"
  names(ret$mcse_divtrans_nonz) <- "divergent_transitions_nonzero_mcse"
  names(ret$mcse_divtrans_nonzmean) <- "divergent_transitionsnonzero_mean_mcse"
  
  
  #- Return
  ret_vec <- unlist(ret, use.names = TRUE)
  ret_vec <- c(ret_vec, named_pms)

  
  return(ret_vec)
}

#' 
#' 
#' # Run Simulation
#' 
## ----sim-run--------------------------------------------------------------
# Simulation Parameters
n_rep <- 500
sim_pars$n_chains <- 4
sim_pars$iter_warmup <- 500
sim_pars$iter_sampling <- 1000
n_cores <- parallel::detectCores() - 1

# for tests
#df_design <- df_design[1,]

# Run Simulation
sim_res <- SimDesign::runSimulation(
  design = df_design,
  replications = n_rep,
  generate = sim_generate,
  analyse = sim_analyze,
  summarise = sim_summarize,
  fixed_objects = sim_pars,
  parallel = TRUE,
  packages = packages,
  save_results = TRUE,
  # debug = "summarise",
  ncores = n_cores,
  max_errors = 2,
  filename =  "sim_res_itm",
  save_details = list(
    save_results_dirname = "full_sim_results_itm"
  )
)

# Save results

# create a folder for the results
path <- here("sim_results",
             paste0(
               "sim_results_itm_",
               Sys.time() %>% format("%Y-%m-%d_%H-%M-%S")
             ))

dir.create(path)
# save session info
writeLines(capture.output(sessionInfo()), here(path,"sim_res_itm_sessionInfo.txt"))
# move the results to the folder
file.rename(from = "full_sim_results_itm",
            to = here(path, "full_sim_results_itm"))
# move rds file
file.rename(from = "sim_res_itm.rds",
            to = here(path, "sim_res_itm.rds"))

#' 
## -------------------------------------------------------------------------
# Clean up
SimClean()

sim_res

#' 
#' 
#' # Write to .R-file
#' 
#' To run this simulation study on a server, we need to write the code to an .R-file. 
#' 
## -------------------------------------------------------------------------
# knitr::purl(here("src", "01_simulation_study_final_v2.Rmd"),
#             output = here("src", "01_simulation_study_final_v2.R"),
#             documentation = 2)

#' 
#' 
#' 
#' 
#' 
