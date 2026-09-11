#!/usr/bin/env julia
# =============================================================================
# event_analysis.jl
# For Ignacio's collaboration — GB comparison with JHU and Melbourne.
#
# Run in the same Julia session as the build script.
# ROOT, WEATHER_YEAR, SIM_YEAR, N_HOURS, SEED are inherited from that session. Collects system_details_table.csv and the event
# scatter plot, consistent with Tim Kopka's Melbourne approach.
#
# Does NOT require PRASNEM — event detection is implemented here directly
# from ShortfallSamples, matching PRASNEM.get_all_event_details() logic.
# =============================================================================

using CSV, DataFrames, Statistics, PRAS, Serialization

# ── SETTINGS ─────────────────────────────────────────────────────────────────
# ROOT, WEATHER_YEAR, SIM_YEAR, N_HOURS, SEED are all inherited from the
# build script session. Only SAMPLES is new here.
SAMPLES = 100    # ShortfallSamples: 10 for preliminary, 100 for final
SEED    = 42    # random seed for reproducibility

# ── LOAD SYSTEM ──────────────────────────────────────────────────────────────
println("Loading system from pras_system.jls...")
sys = deserialize(joinpath(ROOT, "pras_system.jls"))

# ── 1. SYSTEM DETAILS TABLE ──────────────────────────────────────────────────
println("\n" * "="^60)
println("SYSTEM DETAILS — $(basename(ROOT))")
println("="^60)

VRE_CATS = Set(["wind_onshore","wind_offshore","solar_pv",
                 "embedded_wind","embedded_solar"])
is_vre     = BitVector([c in VRE_CATS for c in sys.generators.categories])
is_thermal = .!is_vre

peak_demand      = Float64(maximum(vec(sum(sys.regions.load, dims=1))))
vre_capacity     = Float64(sum(maximum(sys.generators.capacity[is_vre, :],     dims=2)))
thermal_capacity = Float64(sum(maximum(sys.generators.capacity[is_thermal, :], dims=2)))
storage_MW       = Float64(sum(maximum(sys.storages.discharge_capacity,          dims=2)))
annual_demand_mwh= Float64(sum(sys.regions.load))

# Annual VRE CF: mean hourly output / nameplate
vre_annual_output = Float64(sum(sys.generators.capacity[is_vre, :]))
vre_cf_pct        = 100.0 * (vre_annual_output / size(sys.generators.capacity,2)) / vre_capacity

println("Simulation year:        2035")
println("Weather year:           $DISPLAY_WEATHER_YEAR (WY, from build script)")
println("Number of zones:        ", length(sys.regions.names))
println("Peak demand:            ", round(Int, peak_demand), " MW")
println()
println("Thermal capacity:       ", round(Int, thermal_capacity), " MW",
        "  (", round(100*thermal_capacity/peak_demand, digits=1), "% of peak)")
println("VRE capacity:           ", round(Int, vre_capacity), " MW",
        "  (", round(100*vre_capacity/peak_demand, digits=1), "% of peak, nameplate)")
println("Storage discharge:      ", round(Int, storage_MW), " MW",
        "  (", round(100*storage_MW/peak_demand, digits=1), "% of peak)")
println("DR capacity:            0 MW  (0% — flexibility via H2 storage only)")
println("VRE annual mean CF:     ", round(vre_cf_pct, digits=1), "%")
println("Annual demand:          ", round(annual_demand_mwh/1e6, digits=3), " TWh")

table_row = DataFrame(
    scenario           = [basename(ROOT)],
    weather_year       = [DISPLAY_WEATHER_YEAR],
    simulation_year    = [2035],
    n_zones            = [length(sys.regions.names)],
    peak_demand_mw     = [round(Int, peak_demand)],
    thermal_cap_mw     = [round(Int, thermal_capacity)],
    thermal_pct_peak   = [round(100*thermal_capacity/peak_demand, digits=1)],
    vre_cap_mw         = [round(Int, vre_capacity)],
    vre_pct_peak       = [round(100*vre_capacity/peak_demand, digits=1)],
    storage_cap_mw     = [round(Int, storage_MW)],
    storage_pct_peak   = [round(100*storage_MW/peak_demand, digits=1)],
    dr_pct_peak        = [0.0],
    vre_annual_cf_pct  = [round(vre_cf_pct, digits=1)],
    annual_demand_twh  = [round(annual_demand_mwh/1e6, digits=3)],
)
CSV.write(joinpath(ROOT, "system_details_table.csv"), table_row)
println("  → Saved system_details_table.csv")

# ── 2. ShortfallSamples ASSESSMENT ───────────────────────────────────────────
println("\n" * "="^60)
println("RUNNING ShortfallSamples ($SAMPLES samples, seed=$SEED)")
println("="^60)
println("Note: reduces to $(SAMPLES) samples for memory efficiency.")
println("Increase SAMPLES for a smoother scatter plot if RAM allows.")

sfsamples, = PRAS.assess(
    sys,
    SequentialMonteCarlo(samples=SAMPLES, seed=SEED),
    ShortfallSamples()
)
println("  Assessment complete.")

# Build system-level shortfall matrix (SAMPLES × n_timesteps)
region_names_v = String.(sys.regions.names)
n_ts           = length(sys.timestamps)
n_regions      = length(region_names_v)

println("  Building system shortfall matrix ($SAMPLES × $n_ts)...")
sys_sf = zeros(Float64, SAMPLES, n_ts)
for (r, region) in enumerate(region_names_v)
    for (t, ts) in enumerate(sys.timestamps)
        # sfsamples[region, timestamp] → Vector{Float64}(SAMPLES)
        sf_vec = sfsamples[region, ts]
        @inbounds sys_sf[:, t] .+= sf_vec
    end
    r % 5 == 0 && print("  Region $r/$n_regions\r")
end
println("  Matrix built.                    ")

# ── 3. EVENT DETECTION ───────────────────────────────────────────────────────
# Replicates PRASNEM.get_all_event_details() logic:
# a "shortfall event" is a maximal contiguous block of hours where the
# total system shortfall across all regions is > 0 in a given sample.

println("  Detecting events across all $SAMPLES samples...")

start_hrs  = Int[]
durations  = Int[]
totals_mwh = Float64[]
sample_ids = Int[]

for k in 1:SAMPLES
    in_event = false
    start_t  = 0
    cum_eue  = 0.0

    for t in 1:n_ts
        sf = sys_sf[k, t]
        if sf > 0.0
            if !in_event
                in_event = true
                start_t  = t
                cum_eue  = sf
            else
                cum_eue += sf
            end
        else
            if in_event
                push!(start_hrs,  start_t)
                push!(durations,  t - start_t)
                push!(totals_mwh, cum_eue)
                push!(sample_ids, k)
                in_event = false
                cum_eue  = 0.0
            end
        end
    end
    if in_event   # event runs to end of year
        push!(start_hrs,  start_t)
        push!(durations,  n_ts - start_t + 1)
        push!(totals_mwh, cum_eue)
        push!(sample_ids, k)
    end
end

events = DataFrame(
    sample            = sample_ids,
    start_hour        = start_hrs,
    duration_hrs      = durations,
    total_eue_mwh     = totals_mwh,
    total_eue_gwh     = totals_mwh ./ 1000.0,
    annual_demand_mwh = fill(annual_demand_mwh, length(start_hrs)),
    eue_ppm           = (totals_mwh ./ annual_demand_mwh) .* 1e6,
)
# Per-year equivalent: divide counts by SAMPLES
events_per_yr = nrow(events) / SAMPLES

CSV.write(joinpath(ROOT, "event_details.csv"), events)
println("  Events detected: ", nrow(events), " total (", round(events_per_yr, digits=1), "/yr equivalent)")
println("  Mean duration:   ", round(mean(events.duration_hrs), digits=2), " hrs")
println("  Max duration:    ", maximum(events.duration_hrs), " hrs")
println("  Max event EUE:   ", round(maximum(events.total_eue_gwh), digits=2), " GWh")
println("  → Saved event_details.csv")

println("\n" * "="^60)
println("DONE. Run pras_master_analysis.m to produce the scatter plot.")
println("event_details.csv is ready for MATLAB.")
println("="^60)