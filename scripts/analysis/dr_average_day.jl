#!/usr/bin/env julia
# =============================================================================
# dr_average_day.jl
# Extracts average-day profiles for the poster figure and the
# direct vs failed-shifting shortfall decomposition.
# Run reload_session.jl first, then dr_impact_analysis.jl, then this.
# =============================================================================
using CSV, DataFrames, Statistics

NO_DR_ROOT = replace(ROOT, "DR" => "")

sf_dr   = Matrix{Float64}(CSV.read(joinpath(ROOT,       "shortfall_mean.csv"), DataFrame; header=false))
sf_nodr = Matrix{Float64}(CSV.read(joinpath(NO_DR_ROOT, "shortfall_mean.csv"), DataFrame; header=false))
sys_sf_dr   = vec(sum(sf_dr,   dims=1))
sys_sf_nodr = vec(sum(sf_nodr, dims=1))
sys_demand  = vec(sum(Float64.(load_matrix), dims=1))

# ── 1. AVERAGE DAY PROFILES ───────────────────────────────────────────────────
println("Computing average day profiles...")

# Renewable CF by hour of day
var_mask    = is_var
vre_nameplate = sum(Float64.(pras_generators.p_nom[var_mask]))
vre_output    = vec(sum(Float64.(gen_capacity[var_mask, :]), dims=1))
vre_cf        = 100.0 .* vre_output ./ vre_nameplate

# Average day (mean across all occurrences of each hour-of-day)
hod_demand_mw    = zeros(24)
hod_cf_pct       = zeros(24)
hod_sf_nodr_mwh  = zeros(24)
hod_sf_dr_mwh    = zeros(24)
hod_n            = zeros(Int, 24)

for t in 1:N_HOURS
    h = mod(t-1, 24) + 1
    hod_demand_mw[h]   += sys_demand[t]
    hod_cf_pct[h]      += vre_cf[t]
    hod_sf_nodr_mwh[h] += sys_sf_nodr[t]
    hod_sf_dr_mwh[h]   += sys_sf_dr[t]
    hod_n[h] += 1
end
hod_demand_mw   ./= hod_n
hod_cf_pct      ./= hod_n
hod_sf_nodr_mwh ./= hod_n
hod_sf_dr_mwh   ./= hod_n

# Effective demand with DR ≈ original demand + shortfall change
# (since same generation: shortfall = demand - generation, so demand_dr = demand_nodr + (sf_dr - sf_nodr))
hod_demand_dr_mw = hod_demand_mw .+ (hod_sf_dr_mwh .- hod_sf_nodr_mwh)

avg_day = DataFrame(
    hour_of_day         = 0:23,
    mean_demand_mw      = round.(hod_demand_mw,    digits=1),
    mean_demand_dr_mw   = round.(hod_demand_dr_mw, digits=1),
    vre_cf_pct          = round.(hod_cf_pct,        digits=2),
    mean_sf_nodr_mwh    = round.(hod_sf_nodr_mwh,  digits=2),
    mean_sf_dr_mwh      = round.(hod_sf_dr_mwh,    digits=2),
)
CSV.write(joinpath(ROOT, "dr_average_day.csv"), avg_day)
println("  → Saved dr_average_day.csv")

# ── 1b. FIND BEST REPRESENTATIVE DAY ─────────────────────────────────────────
println("\nFinding best representative day...")

best_day, best_score = let
    n_days = N_HOURS ÷ 24
    _best_day = 1; _best_score = -Inf

    for d in 1:n_days
    hrs_eve = ((d-1)*24 + 17):((d-1)*24 + 20)  # 17:00-20:00 of day d
    all(hrs_eve .<= N_HOURS) || continue
    eve_demand = mean(sys_demand[hrs_eve])
    eve_cf     = mean(vre_cf[hrs_eve])
    # Score: high demand + low CF = most stressed evening
    score = eve_demand / max(eve_cf, 1.0)
    if score > _best_score
        _best_score = score
        _best_day   = d
        end
    end
    (_best_day, _best_score)
end  # let

# Extract that day's 24-hour profile
day_start = (best_day-1)*24 + 1
day_end   = min(day_start + 23, N_HOURS)
day_hrs   = day_start:day_end

best_day_df = DataFrame(
    hour_of_day        = 0:23,
    demand_mw          = round.(sys_demand[day_hrs],           digits=1),
    demand_dr_mw       = round.(sys_demand[day_hrs] .+ (sys_sf_dr[day_hrs] .- sys_sf_nodr[day_hrs]), digits=1),
    vre_cf_pct         = round.(vre_cf[day_hrs],               digits=2),
    shortfall_nodr_mwh = round.(sys_sf_nodr[day_hrs],          digits=1),
    shortfall_dr_mwh   = round.(sys_sf_dr[day_hrs],            digits=1),
)
CSV.write(joinpath(ROOT,"dr_best_day.csv"), best_day_df)

# What date is this?
day_timestamp = timestamps[day_start]
println("  Best representative day: Day $best_day (starts at $day_timestamp)")
println("  Evening stress score: $(round(best_score, digits=0))")
println("  Peak demand on this day: $(round(maximum(sys_demand[day_hrs])/1000, digits=1)) GW")
println("  Min VRE CF this day:     $(round(minimum(vre_cf[day_hrs]), digits=1))%")
println("  Shortfall on this day (no-DR): $(round(sum(sys_sf_nodr[day_hrs])/1000, digits=2)) GWh")
println("  → Saved dr_best_day.csv")


println("\nDecomposing shortfalls into direct vs failed-shifting...")

# Classify each hour:
#  "eliminated"      : nodr>0, dr=0         → DR fully resolved it
#  "dr_helped"       : nodr>0, dr < nodr    → DR partially helped
#  "unchanged"       : nodr>0, dr ≈ nodr    → DR had no effect
#  "dr_worsened"     : nodr>0, dr > nodr    → payback landed in already-stressed hour
#  "failed_shifting" : nodr=0, dr > 0       → payback CREATED new shortfall
#  "no_shortfall"    : both = 0

tol = 0.1  # MWh threshold

let
hours_eliminated      = 0; eue_eliminated      = 0.0
hours_helped          = 0; eue_helped          = 0.0
hours_unchanged       = 0; eue_unchanged       = 0.0
hours_worsened        = 0; eue_worsened        = 0.0
hours_failed_shifting = 0; eue_failed_shifting = 0.0

hod_failed  = zeros(24)   # failed-shifting EUE by hour of day
hod_worsened = zeros(24)  # worsened EUE by hour of day
hod_helped   = zeros(24)  # helped EUE by hour of day

decomp_rows = []
for t in 1:N_HOURS
    sn = sys_sf_nodr[t]
    sd = sys_sf_dr[t]
    h  = mod(t-1, 24) + 1

    if sn < tol && sd < tol
        # No shortfall either way — skip
    elseif sn > tol && sd < tol
        hours_eliminated += 1
        eue_eliminated   += sn
        hod_helped[h]    += sn
    elseif sn > tol && sd < sn - tol
        hours_helped += 1
        eue_helped   += (sn - sd)
        hod_helped[h] += (sn - sd)
    elseif sn > tol && abs(sd - sn) <= tol
        hours_unchanged += 1
        eue_unchanged   += sn
    elseif sn > tol && sd > sn + tol
        hours_worsened += 1
        eue_worsened   += (sd - sn)
        hod_worsened[h] += (sd - sn)
    elseif sn < tol && sd > tol
        # FAILED SHIFTING — payback created entirely new shortfall
        hours_failed_shifting += 1
        eue_failed_shifting   += sd
        hod_failed[h] += sd
    end
end

total_eue_dr   = sum(sys_sf_dr)
total_eue_nodr = sum(sys_sf_nodr)

println("\n  SHORTFALL DECOMPOSITION:")
println("  ", rpad("Category",35), rpad("Hours",8), rpad("EUE (GWh)",12), "% of DR EUE")
for (label, hrs, eue) in [
    ("Eliminated by DR (fully helped)",    hours_eliminated,      eue_eliminated),
    ("Partially helped by DR",             hours_helped,          eue_helped),
    ("Unchanged by DR",                    hours_unchanged,       eue_unchanged),
    ("Existing shortfall WORSENED by DR",  hours_worsened,        eue_worsened),
    ("FAILED SHIFTING (new shortfall)",    hours_failed_shifting, eue_failed_shifting),
]
    println("  ", rpad(label,35), rpad(hrs,8), rpad(round(eue/1000,digits=2),12),
            round(100*eue/max(total_eue_dr,1),digits=1), "%")
end

println("\n  Summary:")
dr_benefit   = eue_eliminated + eue_helped
dr_harm      = eue_worsened + eue_failed_shifting
println("  Total benefit from DR (EUE removed): $(round(dr_benefit/1000,digits=1)) GWh")
println("  Total harm from DR (EUE added):      $(round(dr_harm/1000,digits=1)) GWh")
println("  Net EUE change:                      $(round((total_eue_dr-total_eue_nodr)/1000,digits=1)) GWh")
println("  Failed shifting hours:               $hours_failed_shifting ($(round(100*hours_failed_shifting/N_HOURS,digits=1))% of year)")
println("  → These are hours with ZERO shortfall before DR but POSITIVE after = pure payback harm")

# By hour of day
hod_decomp = DataFrame(
    hour_of_day          = 0:23,
    eue_helped_mwh       = round.(hod_helped,   digits=1),
    eue_worsened_mwh     = round.(hod_worsened, digits=1),
    eue_failed_shift_mwh = round.(hod_failed,   digits=1),
)
CSV.write(joinpath(ROOT, "dr_shortfall_decomposition.csv"),
    DataFrame(
        category  = ["Eliminated","Partially helped","Unchanged","Worsened (direct)","Failed shifting (new)"],
        hours     = [hours_eliminated, hours_helped, hours_unchanged, hours_worsened, hours_failed_shifting],
        eue_gwh   = round.([eue_eliminated, eue_helped, eue_unchanged, eue_worsened, eue_failed_shifting]./1000, digits=2),
        pct_dr_eue= round.(100 .* [eue_eliminated, eue_helped, eue_unchanged, eue_worsened, eue_failed_shifting] ./ max(total_eue_dr,1), digits=1),
    )
)
CSV.write(joinpath(ROOT, "dr_decomp_by_hour.csv"), hod_decomp)
println("  → Saved dr_shortfall_decomposition.csv")
println("  → Saved dr_decomp_by_hour.csv")
println("\nDone.")
end # let