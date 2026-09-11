#!/usr/bin/env julia
# =============================================================================
# dr_sensitivity.jl
# Sweeps demand response parameters and records EUE/LOLE for each combination.
# Run in the SAME Julia session as the build script (sys must be in scope).
#
# This avoids re-building the network each time — only the DR object changes.
# Uses 200 samples per run for speed; increase SENS_SAMPLES for more precision.
# =============================================================================

using CSV, DataFrames, Statistics, PRAS

const SENS_SAMPLES = 200   # samples per DR configuration — increase for precision
const SENS_SEED    = 42

println("\n" * "="^60)
println("DEMAND RESPONSE SENSITIVITY SWEEP")
println("="^60)

# ── Parameter grid ────────────────────────────────────────────────────────────
# Add/remove values in any of these vectors to change the sweep
volumes_mw    = [0, 2_500, 5_000, 10_000, 20_000]   # DR_TOTAL_MW
payback_hrs   = [1, 4, 8, 24]                          # DR_PAYBACK_HRS
dr_types      = ["shift", "shed"]                      # DR_TYPE

# ── Baseline: no DR (sys already built, already have results) ─────────────────
println("Running baseline (0 MW DR)...")
baseline_sf, = PRAS.assess(sys,
    SequentialMonteCarlo(samples=SENS_SAMPLES, seed=SENS_SEED), Shortfall())
baseline_eue  = val(EUE(baseline_sf))
baseline_lole = val(LOLE(baseline_sf))
println("  Baseline EUE:  $(round(baseline_eue/1000, digits=1)) GWh")
println("  Baseline LOLE: $(round(baseline_lole, digits=1)) h/yr")

# ── Helper: build DemandResponses for given parameters ───────────────────────
function build_dr(sys, total_mw, payback_h, dr_type)
    n_hours   = length(sys.timestamps)
    r_names   = String.(sys.regions.names)
    load_mat  = sys.regions.load

    VRE_CATS = Set(["wind_onshore","wind_offshore","solar_pv","embedded_wind","embedded_solar"])
    gb_zones  = filter(r -> startswith(r, "Z"), r_names)
    n_regions = length(r_names)

    # Zone demand proportions
    zone_mean = Dict(z => mean(Float64.(load_mat[findfirst(==(z), r_names), :]))
                     for z in gb_zones)
    total_mean = sum(values(zone_mean))

    zone_mw = Dict{String,Int}()
    for z in gb_zones
        zone_mw[z] = max(0, round(Int, total_mw * zone_mean[z] / total_mean))
    end
    # Fix rounding
    largest = gb_zones[argmax([zone_mw[z] for z in gb_zones])]
    diff = total_mw - sum(values(zone_mw))
    zone_mw[largest] = max(0, zone_mw[largest] + diff)

    interest = dr_type == "shed" ? -0.99 : 0.0
    dr_lambda = 1.0 / 2000.0
    dr_mu     = dr_lambda * 0.02 / 0.98

    ordered = [r for r in r_names if startswith(r,"Z") && haskey(zone_mw, r)]

    names_v = ["DR_$(dr_type)_$z" for z in ordered]
    cats_v  = ["DR_$dr_type" for _ in ordered]
    n_dr    = length(names_v)

    borrow  = vcat([reshape(fill(zone_mw[z],    n_hours), 1, :) for z in ordered]...)
    payback = copy(borrow)
    maxe    = vcat([reshape(fill(zone_mw[z]*payback_h, n_hours), 1, :) for z in ordered]...)
    intr    = fill(interest,  n_dr, n_hours)
    pperiod = fill(payback_h, n_dr, n_hours)
    λ_mat   = fill(dr_lambda, n_dr, n_hours)
    μ_mat   = fill(dr_mu,     n_dr, n_hours)

    dr_obj = PRAS.DemandResponses{n_hours,1,Hour,MW,MWh}(
        names_v, cats_v, borrow, payback, maxe, intr, pperiod, λ_mat, μ_mat)

    region_dr_idxs = Vector{UnitRange{Int}}(undef, n_regions)
    let pos = 1
        for (i, r) in enumerate(r_names)
            if haskey(zone_mw, r) && r in Set(ordered)
                region_dr_idxs[i] = pos:pos; pos += 1
            else
                region_dr_idxs[i] = pos:(pos-1)
            end
        end
    end

    return dr_obj, region_dr_idxs
end

# ── Sweep ─────────────────────────────────────────────────────────────────────
function run_sensitivity(sys, volumes_mw, payback_hrs, dr_types,
                          baseline_eue, baseline_lole, baseline_sf)
    rows  = []
    run_n = 0

    for dr_type in dr_types, vol in volumes_mw, phrs in payback_hrs
        (vol == 0 && dr_type == "shed") && continue
        (dr_type == "shed" && phrs != payback_hrs[1]) && continue

        run_n += 1
        label = vol == 0 ? "No DR" : "$(vol÷1000)GW $(dr_type) $(phrs)h"
        print("[$(run_n)] $(label) ... ")

        if vol == 0
            eue      = baseline_eue
            lole     = baseline_lole
            eue_std  = stderror(EUE(baseline_sf))
            lole_std = stderror(LOLE(baseline_sf))
        else
            dr_obj, dr_idxs = build_dr(sys, vol, phrs, dr_type)
            sys_dr = PRAS.SystemModel(
                sys.regions, sys.interfaces,
                sys.generators,        sys.region_gen_idxs,
                sys.storages,          sys.region_stor_idxs,
                sys.generatorstorages, sys.region_genstor_idxs,
                dr_obj, dr_idxs,
                sys.lines, sys.interface_line_idxs,
                sys.timestamps
            )
            sf, = PRAS.assess(sys_dr,
                SequentialMonteCarlo(samples=SENS_SAMPLES, seed=SENS_SEED),
                Shortfall())
            eue      = val(EUE(sf))
            lole     = val(LOLE(sf))
            eue_std  = stderror(EUE(sf))
            lole_std = stderror(LOLE(sf))
        end

        eue_red  = 100*(baseline_eue  - eue)  / baseline_eue
        lole_red = 100*(baseline_lole - lole) / baseline_lole
        println("EUE=$(round(Int,eue/1000)) GWh ($(round(eue_red,digits=1))% down)  " *
                "LOLE=$(round(lole,digits=1)) h ($(round(lole_red,digits=1))% down)")

        push!(rows, (
            dr_type            = vol==0 ? "none" : dr_type,
            volume_mw          = vol,
            payback_hrs        = phrs,
            eue_gwh            = round(eue/1000,  digits=1),
            eue_std_gwh        = round(eue_std/1000, digits=1),
            lole_h             = round(lole,       digits=2),
            lole_std_h         = round(lole_std,   digits=2),
            eue_reduction_pct  = round(eue_red,    digits=2),
            lole_reduction_pct = round(lole_red,   digits=2),
        ))
    end
    return DataFrame(rows)
end

# ── Run the sweep ─────────────────────────────────────────────────────────────
results_df = run_sensitivity(sys, volumes_mw, payback_hrs, dr_types,
                              baseline_eue, baseline_lole, baseline_sf)
sort!(results_df, [:dr_type, :volume_mw, :payback_hrs])
CSV.write(joinpath(ROOT, "dr_sensitivity.csv"), results_df)

println("\n" * "="^60)
println("SENSITIVITY RESULTS")
println("="^60)
println(results_df)
println("\n  → Saved dr_sensitivity.csv")
