#!/usr/bin/env julia
# =============================================================================
# dr_sample_case_study.jl
#
# Finds a Monte Carlo sample where DR reduces EUE but increases LOLE,
# then traces PRAS's hour-by-hour decisions in that sample to show the
# payback mechanism explicitly.
#
# Run reload_session.jl first in the DR session.
# Requires: pras_system.jls from both DR and no-DR folders.
# =============================================================================

using PRAS, CSV, DataFrames, Statistics, Serialization

DR_PAYBACK_HRS = 4
SAMPLES        = 200
SEED           = 42
NO_DR_ROOT     = replace(ROOT, "DR" => "")

println("="^70)
println("DR SAMPLE CASE STUDY")
println("="^70)
println("Running ShortfallSamples for DR and no-DR ($SAMPLES samples each)...")

# ── Load both systems ─────────────────────────────────────────────────────────
sys_dr   = sys   # already loaded from reload_session.jl
sys_nodr = deserialize(joinpath(NO_DR_ROOT, "pras_system.jls"))

# Ensure region_names is defined (may not be in scope if reload_session wasn't used)
if !@isdefined(region_names)
    region_names = String.(sys_dr.regions.names)
end
if !@isdefined(timestamps)
    timestamps = sys_dr.timestamps
end
if !@isdefined(N_HOURS)
    N_HOURS = length(timestamps)
end

# ── Run ShortfallSamples for both ────────────────────────────────────────────
sf_dr_samples   = PRAS.assess(sys_dr,   SequentialMonteCarlo(samples=SAMPLES, seed=SEED), ShortfallSamples())
sf_nodr_samples = PRAS.assess(sys_nodr, SequentialMonteCarlo(samples=SAMPLES, seed=SEED), ShortfallSamples())

println("  Done. Extracting per-sample metrics...")

# ── Build per-sample EUE and LOLE matrices ────────────────────────────────────
n_regions = length(region_names)
gb_regions = filter(r -> startswith(r,"Z"), region_names)

# System shortfall per sample per hour
sys_sf_dr   = zeros(Float64, SAMPLES, N_HOURS)
sys_sf_nodr = zeros(Float64, SAMPLES, N_HOURS)

for (ri, region) in enumerate(region_names)
    startswith(region, "Z") || continue
    for (ti, ts) in enumerate(timestamps)
        dr_vals   = sf_dr_samples[region,   ts]
        nodr_vals = sf_nodr_samples[region, ts]
        for k in 1:SAMPLES
            sys_sf_dr[k,   ti] += dr_vals[k]
            sys_sf_nodr[k, ti] += nodr_vals[k]
        end
    end
end

println("  Matrices built. Computing per-sample metrics...")

# Per-sample EUE and LOLE
eue_dr   = vec(sum(sys_sf_dr,   dims=2))
eue_nodr = vec(sum(sys_sf_nodr, dims=2))
lole_dr   = vec(sum(sys_sf_dr   .> 0.1, dims=2))
lole_nodr = vec(sum(sys_sf_nodr .> 0.1, dims=2))

delta_eue  = eue_dr  .- eue_nodr    # negative = DR reduced EUE
delta_lole = lole_dr .- lole_nodr   # positive = DR increased LOLE

# ── Find samples where EUE decreases AND LOLE increases ──────────────────────
interesting = findall((delta_eue .< -100) .& (delta_lole .> 0))
println("\n  Samples where EUE↓ AND LOLE↑: $(length(interesting)) out of $SAMPLES")

if isempty(interesting)
    println("  No clear examples found — try increasing SAMPLES")
else
    # Pick the sample with the largest LOLE increase relative to EUE decrease
    scores = -delta_eue[interesting] ./ max.(delta_lole[interesting], 1)
    best_k = interesting[argmax(scores)]

    println("\n  Best example: Sample #$best_k")
    println("    No-DR:  EUE=$(round(eue_nodr[best_k]/1000,digits=2)) GWh,  LOLE=$(lole_nodr[best_k]) hrs")
    println("    With DR: EUE=$(round(eue_dr[best_k]/1000,digits=2)) GWh,  LOLE=$(lole_dr[best_k]) hrs")
    println("    EUE change:  $(round(delta_eue[best_k]/1000,digits=2)) GWh  ← DR reduced EUE")
    println("    LOLE change: +$(delta_lole[best_k]) hrs  ← DR increased shortfall frequency")

    # ── Trace the hour-by-hour decisions ─────────────────────────────────────
    sf_dr_k   = vec(sys_sf_dr[best_k,   :])
    sf_nodr_k = vec(sys_sf_nodr[best_k, :])
    delta_k   = sf_dr_k .- sf_nodr_k

    # Identify key hours
    borrowed_hrs = findall((sf_nodr_k .> 0.1) .& (sf_dr_k .< sf_nodr_k .- 0.1))
    worsened_hrs = findall((sf_nodr_k .> 0.1) .& (sf_dr_k .> sf_nodr_k .+ 0.1))
    new_sf_hrs   = findall((sf_nodr_k .< 0.1) .& (sf_dr_k .> 0.1))

    println("\n  Hour classification in sample #$best_k:")
    println("    Hours DR helped (reduced shortfall):  $(length(borrowed_hrs))")
    println("    Hours DR worsened (increased shortfall): $(length(worsened_hrs))")
    println("    Hours DR created NEW shortfall:       $(length(new_sf_hrs))")

    if !isempty(new_sf_hrs)
        println("\n  NEW shortfall hours (key evidence):")
        for t in new_sf_hrs[1:min(5,length(new_sf_hrs))]
            h = mod(t-1,24)
            prior_stress = mean(sf_nodr_k[max(1,t-DR_PAYBACK_HRS):max(1,t-1)])
            println("    Hour $t ($(h):00): new shortfall=$(round(sf_dr_k[t],digits=1)) MWh, ",
                    "system was stressed $(round(prior_stress,digits=1)) MWh/hr in prior $DR_PAYBACK_HRS hrs")
        end
    end

    # Find the event window to zoom in on
    all_active = sort(union(borrowed_hrs, worsened_hrs, new_sf_hrs))
    if !isempty(all_active)
        window_start = max(1, minimum(all_active) - 12)
        window_end   = min(N_HOURS, maximum(all_active) + 12)
        window_hrs   = window_start:window_end

        # Save the zoomed window for plotting
        case_df = DataFrame(
            hour         = collect(window_hrs),
            hour_of_day  = mod.(collect(window_hrs) .- 1, 24),
            sf_nodr_mwh  = round.(sf_nodr_k[window_hrs], digits=1),
            sf_dr_mwh    = round.(sf_dr_k[window_hrs],   digits=1),
            delta_mwh    = round.(delta_k[window_hrs],    digits=1),
            dr_helped    = (sf_nodr_k[window_hrs] .> 0.1) .& (sf_dr_k[window_hrs] .< sf_nodr_k[window_hrs] .- 0.1),
            dr_worsened  = (sf_nodr_k[window_hrs] .> 0.1) .& (sf_dr_k[window_hrs] .> sf_nodr_k[window_hrs] .+ 0.1),
            new_shortfall= (sf_nodr_k[window_hrs] .< 0.1) .& (sf_dr_k[window_hrs] .> 0.1),
        )
        CSV.write(joinpath(ROOT, "dr_case_study_window.csv"), case_df)

        # Save the full year for context
        full_df = DataFrame(
            hour        = 1:N_HOURS,
            sf_nodr_mwh = round.(sf_nodr_k, digits=1),
            sf_dr_mwh   = round.(sf_dr_k,   digits=1),
            delta_mwh   = round.(delta_k,    digits=1),
        )
        CSV.write(joinpath(ROOT, "dr_case_study_full.csv"), full_df)

        # Save summary
        summary_df = DataFrame(
            sample_id      = [best_k],
            eue_nodr_gwh   = [round(eue_nodr[best_k]/1000,digits=2)],
            eue_dr_gwh     = [round(eue_dr[best_k]/1000,  digits=2)],
            eue_delta_gwh  = [round(delta_eue[best_k]/1000,digits=2)],
            lole_nodr_h    = [lole_nodr[best_k]],
            lole_dr_h      = [lole_dr[best_k]],
            lole_delta_h   = [delta_lole[best_k]],
            hrs_dr_helped  = [length(borrowed_hrs)],
            hrs_dr_worsened= [length(worsened_hrs)],
            hrs_new_sf     = [length(new_sf_hrs)],
            window_start   = [window_start],
            window_end     = [window_end],
        )
        CSV.write(joinpath(ROOT, "dr_case_study_summary.csv"), summary_df)

        println("\n  → Saved dr_case_study_window.csv  (zoomed event window)")
        println("  → Saved dr_case_study_full.csv    (full year for context)")
        println("  → Saved dr_case_study_summary.csv (key metrics)")
        println("\n  Run dr_case_study_plot.m in MATLAB to produce the figure.")
    end
end

println("\n" * "="^70)
println("DONE")
println("="^70)