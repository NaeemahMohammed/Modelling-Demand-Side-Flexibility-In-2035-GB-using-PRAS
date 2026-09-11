#!/usr/bin/env julia
# =============================================================================
# worst_10_analysis.jl
#
# Comprehensive analysis of the 10 worst system shortfall events.
# Must be run in the SAME Julia session as the build script so that
# the following variables are still in scope:
#   ROOT, N_HOURS, region_names, region_index, load_matrix,
#   pras_generators, gen_capacity, gen_categories, is_variable,
#   internal_links, timestamps
#
# Reads:  shortfall_mean.csv  (from extract_results.jl)
#
# Writes to ROOT:
#   top10_summary.csv          — one row per top-10 hour
#   top10_zone_breakdown.csv   — shortfall by zone × top-10 hour
#   top10_renewable_profile.csv— renewable availability at each top-10 hour
#   top10_structural.csv       — demand decomposition at each top-10 hour
#   top10_transmission.csv     — line capacity vs importable per zone
#   hourly_pct_demand.csv      — full-year shortfall as % of demand (scatter)
#   top10_matlab_zone_matrix.csv  — zone × rank matrix for stacked bar
#   top10_matlab_structural_matrix.csv — components × rank matrix
# =============================================================================

using CSV, DataFrames, Statistics

println("\n" * "="^70)
println("WORST-10 SHORTFALL EVENTS — COMPREHENSIVE ANALYSIS")
println("="^70)

# --- Load shortfall_mean ----------------------------------------------------
sf_path = joinpath(ROOT, "shortfall_mean.csv")
isfile(sf_path) || error("Run extract_results.jl first to generate shortfall_mean.csv")
shortfall_mat = Matrix{Float64}(CSV.read(sf_path, DataFrame; header=false))
n_reg_csv, _ = size(shortfall_mat)

# Sorted region names matching CSV row order (same order as extract_results.jl)
function zone_sort_key(name::AbstractString)
    m = match(r"^Z(\d+)(?:_(\d+))?$", name)
    m === nothing && return (typemax(Int), typemax(Int))
    (parse(Int, m.captures[1]), m.captures[2] === nothing ? 0 : parse(Int, m.captures[2]))
end
gb_zones     = sort(filter(r -> startswith(r, "Z"), region_names), by=zone_sort_key)
sorted_regs  = vcat(gb_zones, filter(r -> !startswith(r, "Z"), region_names))
# Clip to the number of rows actually in the CSV — protects against the build
# script session having more regions (e.g. GB_H2) than were exported by
# extract_results.jl (which may be an older version without GB_H2).
sorted_regs  = sorted_regs[1:n_reg_csv]

# --- System aggregates -------------------------------------------------------
sys_shortfall = vec(sum(shortfall_mat, dims=1))   # MWh per hour
sys_demand    = vec(sum(load_matrix,   dims=1))   # MW  per hour
total_eue     = sum(sys_shortfall)
n_nonzero     = count(>(0.0), sys_shortfall)

println("Scenario:   ", ROOT)
println("EUE:        ", round(total_eue/1000, digits=2), " GWh")
println("LOLE (hrs): ", n_nonzero, " hours with non-zero expected shortfall out of $N_HOURS")

# --- Variable renewable mask ------------------------------------------------
variable_carriers = Set(["wind_onshore","wind_offshore","solar_pv",
                          "embedded_wind","embedded_solar"])
is_var = [c in variable_carriers for c in gen_categories]
var_nameplate     = sum(pras_generators.p_nom[is_var])
annual_mean_var   = mean(vec(sum(gen_capacity[is_var, :], dims=1)))

# Expected thermal (non-variable) available capacity: nameplate × (1-FOR)
is_therm = .!is_var
exp_therm_total = sum(pras_generators.p_nom[is_therm] .* (1.0 .- Float64.(pras_generators.FOR[is_therm])))

println("\nVariable renewable nameplate:    ", round(var_nameplate,     digits=0), " MW")
println("Annual mean renewable output:    ", round(annual_mean_var,    digits=0), " MW")
println("Expected thermal capacity (avg): ", round(exp_therm_total,    digits=0), " MW")

# ============================================================================
# DEFINITION BLOCK — printed once, for your write-up
# ============================================================================
println("""
\n--- DEFINITION OF 'WORST EVENT' (paste into dissertation) ---
The 10 worst events are identified as the hours with the highest total system
Expected Unserved Energy (EUE, MWh), where EUE at each hour is the mean
shortfall across 1,000 sequential Monte Carlo simulations. An 'event' is a
single calendar hour; consecutive hours can both appear in the ranking if a
prolonged system stress period occurs. Ranking by EUE captures severity (how
much energy goes unmet on average), distinct from LOLE which measures frequency.

Because Shortfall() stores the mean outcome across draws, the analysis below
cannot identify which specific generator failed in any individual simulation.
Instead, shortfall is decomposed into:
  (a) STRUCTURAL COMPONENT: demand minus actual renewable output minus expected
      thermal capacity (Σ p_nom × (1−FOR)). This is positive when demand
      structurally exceeds expected supply even before any random outage.
  (b) STOCHASTIC COMPONENT: shortfall above (a), attributable to above-average
      forced outages in the random draws. This is the Monte Carlo element that
      Shortfall() captures as an average.
""")

# ============================================================================
# TOP 10 IDENTIFICATION
# ============================================================================
top10_idx = sortperm(sys_shortfall, rev=true)[1:10]

println("="^70)
println("TOP 10 WORST HOURS")
println("="^70)
println(rpad("Rank",5), rpad("Hour",7), rpad("Timestamp",22),
        rpad("Demand MW",11), rpad("Shortfall MWh",15),
        rpad("% Demand",10), "Zones")

summary_rows = []
for (rank, t) in enumerate(top10_idx)
    demand    = sys_demand[t]
    sf_t      = sys_shortfall[t]          # renamed to avoid clash with PRAS `shortfall` object
    pct       = 100.0 * sf_t / demand
    zones_hit = [sorted_regs[r] for r in 1:n_reg_csv
                 if shortfall_mat[r, t] > 0.1]
    ts_str    = string(timestamps[t])

    println(rpad(rank,5), rpad(t,7), rpad(ts_str,22),
            rpad(round(Int,demand),11), rpad(round(sf_t,digits=1),15),
            rpad(string(round(pct,digits=2))*"%",10), join(zones_hit, ", "))

    push!(summary_rows, (rank           = rank,
                          hour           = t,
                          timestamp      = ts_str,
                          demand_mw      = round(Int, demand),
                          shortfall_mwh  = round(sf_t, digits=1),
                          pct_of_demand  = round(pct, digits=3),
                          zones_affected = join(zones_hit, "|")))
end
summary_df = DataFrame(summary_rows)
CSV.write(joinpath(ROOT, "top10_summary.csv"), summary_df)
println("\n  → Saved top10_summary.csv")

# ============================================================================
# PER-ZONE BREAKDOWN
# ============================================================================
println("\n" * "="^70)
println("PER-ZONE BREAKDOWN OF EACH TOP-10 HOUR")
println("="^70)

zone_rows = []
# Also build a matrix (zones × ranks) for the MATLAB stacked bar
zone_matrix = zeros(Float64, n_reg_csv, 10)

for (rank, t) in enumerate(top10_idx)
    total_sf = sys_shortfall[t]
    demand_t = sys_demand[t]
    println("\nRank $rank | Hour $t | System shortfall = ",
            round(total_sf,digits=1), " MWh | Demand = ",
            round(Int,demand_t), " MW | Shortfall = ",
            round(100*total_sf/demand_t, digits=2), "% of demand")

    for (r, region) in enumerate(sorted_regs)
        zone_sf  = shortfall_mat[r, t]
        zone_matrix[r, rank] = zone_sf
        zone_sf < 0.01 && continue

        ri = findfirst(==(region), region_names)
        zone_dem = ri !== nothing ? load_matrix[ri, t] : 0
        pct_sys  = total_sf > 0 ? 100*zone_sf/total_sf  : 0.0
        pct_dem  = zone_dem > 0 ? 100*zone_sf/zone_dem  : 0.0

        println("  ", rpad(region,8),
                " | shortfall: ", rpad(round(zone_sf,digits=1),10), " MWh",
                " | ", rpad(round(pct_sys,digits=1),6), "% of system shortfall",
                " | ", round(pct_dem,digits=2), "% of zone demand")

        push!(zone_rows, (rank=rank, hour=t, zone=region,
                           zone_shortfall_mwh       = round(zone_sf,  digits=2),
                           zone_demand_mw            = zone_dem,
                           pct_of_system_shortfall   = round(pct_sys, digits=2),
                           pct_of_zone_demand        = round(pct_dem, digits=3)))
    end
end
zone_df = DataFrame(zone_rows)
CSV.write(joinpath(ROOT, "top10_zone_breakdown.csv"), zone_df)

# Build zone × rank matrix for MATLAB stacked bar.
# Build column-by-column to guarantee lengths always match.
zone_mat_df = DataFrame(zone = String.(sorted_regs))
for i in 1:10
    zone_mat_df[!, "rank_$i"] = zone_matrix[:, i]
end
CSV.write(joinpath(ROOT, "top10_matlab_zone_matrix.csv"), zone_mat_df)
println("\n  → Saved top10_zone_breakdown.csv + top10_matlab_zone_matrix.csv")

# ============================================================================
# RENEWABLE AVAILABILITY ANALYSIS
# ============================================================================
println("\n" * "="^70)
println("RENEWABLE AVAILABILITY AT EACH TOP-10 HOUR")
println("="^70)
println("(Annual mean capacity factor: ", round(100*annual_mean_var/var_nameplate, digits=1), "%)")
println()
println(rpad("Rank",5), rpad("Hour",7), rpad("Var output MW",15),
        rpad("CF%",7), rpad("vs avg",8),
        rpad("Wind on MW",12), rpad("Wind off MW",13), "Solar MW")

ren_rows = []
for (rank, t) in enumerate(top10_idx)
    var_out = sum(gen_capacity[is_var, t])
    cf_t    = var_out / var_nameplate
    delta   = 100*(cf_t - annual_mean_var/var_nameplate)

    carriers_mw = Dict{String,Float64}()
    for c in ["wind_onshore","wind_offshore","solar_pv","embedded_wind","embedded_solar"]
        mask = [gen_categories[i] == c for i in eachindex(gen_categories)]
        carriers_mw[c] = sum(gen_capacity[mask, t])
    end
    wind_on  = get(carriers_mw,"wind_onshore",0) + get(carriers_mw,"embedded_wind",0)
    wind_off = get(carriers_mw,"wind_offshore",0)
    solar    = get(carriers_mw,"solar_pv",0) + get(carriers_mw,"embedded_solar",0)

    println(rpad(rank,5), rpad(t,7),
            rpad(round(Int,var_out),15),
            rpad(round(100*cf_t,digits=1),7),
            rpad((delta >= 0 ? "+" : "") * string(round(delta,digits=1)) * "%", 8),
            rpad(round(Int,wind_on),12),
            rpad(round(Int,wind_off),13),
            round(Int,solar))

    push!(ren_rows, (rank=rank, hour=t,
                     variable_mw           = round(Int,var_out),
                     capacity_factor_pct   = round(100*cf_t,   digits=2),
                     annual_mean_cf_pct    = round(100*annual_mean_var/var_nameplate, digits=2),
                     vs_annual_avg_ppt     = round(delta,       digits=2),
                     wind_onshore_mw       = round(Int,wind_on),
                     wind_offshore_mw      = round(Int,wind_off),
                     solar_mw              = round(Int,solar)))
end
ren_df = DataFrame(ren_rows)
CSV.write(joinpath(ROOT, "top10_renewable_profile.csv"), ren_df)
println("\n  → Saved top10_renewable_profile.csv")

# ============================================================================
# STRUCTURAL DECOMPOSITION
# ============================================================================
println("\n" * "="^70)
println("STRUCTURAL DECOMPOSITION OF EACH TOP-10 HOUR")
println("="^70)
println("Structural gap = Demand − Actual renewable − Expected thermal (nameplate×(1−FOR))")
println("Structural%    = structural gap / observed shortfall × 100")
println("Interpretation: high % → weather/firm-capacity driven; low % → random outage driven")
println()
println(rpad("Rank",5), rpad("Demand MW",11), rpad("Renewable MW",14),
        rpad("Exp.Therm MW",14), rpad("Struct gap MW",15),
        rpad("Shortfall MWh",15), rpad("Struct%",9), "Interpretation")

struct_rows = []
struct_matrix = zeros(Float64, 4, 10)  # rows: renewable, thermal, struct_gap, stochastic

for (rank, t) in enumerate(top10_idx)
    demand    = sys_demand[t]
    renewable = sum(gen_capacity[is_var, t])
    struct_gap= max(0.0, demand - renewable - exp_therm_total)
    sf_t      = sys_shortfall[t]          # renamed to avoid clash with PRAS `shortfall` object
    struct_pct= sf_t > 0 ? min(100.0, 100*struct_gap/sf_t) : 0.0
    stochastic= max(0.0, sf_t - struct_gap)

    interp = if struct_pct > 80
        "Structural: demand > renewable + expected thermal"
    elseif struct_pct > 40
        "Mixed: structural deficit + random outages"
    else
        "Stochastic: average supply sufficient but random outages tip over"
    end

    println(rpad(rank,5), rpad(round(Int,demand),11),
            rpad(round(Int,renewable),14),
            rpad(round(Int,exp_therm_total),14),
            rpad(round(Int,struct_gap),15),
            rpad(round(sf_t,digits=1),15),
            rpad(string(round(struct_pct,digits=1))*"%",9), interp)

    struct_matrix[1, rank] = renewable
    struct_matrix[2, rank] = min(exp_therm_total, demand - renewable)
    struct_matrix[3, rank] = struct_gap
    struct_matrix[4, rank] = stochastic

    push!(struct_rows, (rank=rank, hour=t,
                         demand_mw            = round(Int,demand),
                         renewable_mw         = round(Int,renewable),
                         expected_thermal_mw  = round(Int,exp_therm_total),
                         structural_gap_mw    = round(Int,struct_gap),
                         shortfall_mwh        = round(sf_t,digits=1),
                         shortfall_pct_demand = round(100*sf_t/demand,digits=3),
                         structural_pct       = round(struct_pct,digits=2),
                         stochastic_mwh       = round(stochastic,digits=1)))
end
struct_df = DataFrame(struct_rows)
CSV.write(joinpath(ROOT, "top10_structural.csv"), struct_df)
struct_mat_df = DataFrame(struct_matrix', ["renewable","expected_thermal","structural_gap","stochastic"])
CSV.write(joinpath(ROOT, "top10_matlab_structural_matrix.csv"), struct_mat_df)
println("\n  → Saved top10_structural.csv + top10_matlab_structural_matrix.csv")

# ============================================================================
# TRANSMISSION ANALYSIS
# ============================================================================
println("\n" * "="^70)
println("TRANSMISSION ANALYSIS FOR EACH TOP-10 HOUR")
println("="^70)
println("For each zone in shortfall: compares shortfall to available import capacity")
println("Importable = min(line_cap, neighbour_surplus) summed across all connected lines")
println()

trans_rows = []
for (rank, t) in enumerate(top10_idx)
    total_sf = sys_shortfall[t]
    println("\nRank $rank | Hour $t | System shortfall = ", round(total_sf,digits=1), " MWh")

    for (r, region) in enumerate(sorted_regs)
        zone_sf = shortfall_mat[r, t]
        zone_sf < 0.1 && continue

        ri = findfirst(==(region), region_names)
        zone_dem = ri !== nothing ? load_matrix[ri, t] : 0

        # Lines connecting this zone
        connected = filter(row -> strip(String(row.bus0)) == region ||
                                   strip(String(row.bus1)) == region, internal_links)

        total_line_cap   = 0.0
        total_importable = 0.0
        n_lines          = nrow(connected)

        for row in eachrow(connected)
            nb = strip(String(row.bus0)) == region ? strip(String(row.bus1)) : strip(String(row.bus0))
            lc = Float64(row.p_nom)
            ni = findfirst(==(nb), region_names)
            if ni !== nothing
                nb_gen = sum(gen_capacity[String.(pras_generators.bus) .== nb, t])
                nb_dem = load_matrix[ni, t]
                nb_csv_idx = findfirst(==(nb), sorted_regs)
                nb_sfx     = nb_csv_idx !== nothing ? shortfall_mat[nb_csv_idx, t] : 0.0
                nb_surplus = max(0.0, nb_gen - nb_dem - nb_sfx)
                total_importable += min(lc, nb_surplus)
            end
            total_line_cap += lc
        end

        pct_covered = total_line_cap > 0 ? 100*total_importable/zone_sf : 0.0
        bottleneck  = if total_line_cap < zone_sf * 0.5
            "LINE CAPACITY BINDING"
        elseif total_importable < zone_sf * 0.5
            "NEIGHBOR CAPACITY BINDING"
        elseif total_importable < zone_sf
            "PARTIALLY COVERED by transmission"
        else
            "Transmission CAN cover (dispatch/routing issue)"
        end

        println("  ", rpad(region,8),
                " | shortfall: ", rpad(round(zone_sf,digits=1),9), " MWh",
                " | lines: $n_lines (cap=", round(Int,total_line_cap), " MW)",
                " | importable: ", round(Int,total_importable), " MW",
                " | → $bottleneck")

        push!(trans_rows, (rank=rank, hour=t, zone=region,
                            zone_shortfall_mwh      = round(zone_sf,digits=1),
                            zone_demand_mw           = zone_dem,
                            n_connected_lines        = n_lines,
                            total_line_capacity_mw   = round(Int,total_line_cap),
                            total_importable_mw      = round(Int,total_importable),
                            pct_shortfall_coverable  = round(min(100.0,pct_covered),digits=1),
                            bottleneck               = bottleneck))
    end
end
trans_df = DataFrame(trans_rows)
CSV.write(joinpath(ROOT, "top10_transmission.csv"), trans_df)
println("\n  → Saved top10_transmission.csv")

# ============================================================================
# FULL-YEAR SHORTFALL AS % OF DEMAND (for scatter plot)
# ============================================================================
hourly_pct = 100.0 .* sys_shortfall ./ sys_demand

pct_df = DataFrame(
    hour                 = 1:N_HOURS,
    shortfall_mwh        = round.(sys_shortfall, digits=2),
    demand_mw            = sys_demand,
    shortfall_pct_demand = round.(hourly_pct, digits=4),
    nonzero              = Int.(sys_shortfall .> 0.0),
    in_top10             = Int.([t in top10_idx for t in 1:N_HOURS])
)
CSV.write(joinpath(ROOT, "hourly_pct_demand.csv"), pct_df)

nonzero_pct = hourly_pct[sys_shortfall .> 0.0]
println("\n" * "="^70)
println("FULL-YEAR SHORTFALL AS % OF DEMAND")
println("="^70)
println("Hours with any shortfall: ", count(>(0), sys_shortfall), " / $N_HOURS")
if !isempty(nonzero_pct)
    println("Shortfall as % of demand (non-zero hours):")
    println("  Mean:      ", round(mean(nonzero_pct),     digits=3), "%")
    println("  Median:    ", round(median(nonzero_pct),   digits=3), "%")
    println("  90th pctl: ", round(quantile(nonzero_pct,0.9), digits=3), "%")
    println("  Max:       ", round(maximum(nonzero_pct),  digits=3), "%  (hour $(top10_idx[1]))")
end
println("  → Saved hourly_pct_demand.csv")

# ============================================================================
# SECTION A: EVENT CLUSTERING
# Groups consecutive shortfall hours into stress "events" and re-ranks them.
# This is complementary to the hourly ranking:
#   Hourly: worst single hour (intensity)
#   Event:  worst prolonged stress period (duration × severity combined)
# ============================================================================
println("\n" * "="^70)
println("EVENT CLUSTERING — CONSECUTIVE SHORTFALL HOURS")
println("="^70)
println("""
Definition: a stress EVENT is a maximal sequence of consecutive hours each
with system shortfall > 0 MWh. Events are ranked by TOTAL EUE (sum of
hourly shortfalls), which captures both severity and duration. A single
event can span multiple hours when the system continuously fails to meet
demand — e.g. a prolonged winter anticyclone with no wind.
""")

# Group consecutive non-zero shortfall hours
# Wrap in a function so all variables have hard (function) scope — avoids
# Julia's soft-scope warnings when reassigning inside for loops at top level.
function cluster_consecutive(shortfall_vec::Vector{Float64})
    nz = findall(shortfall_vec .> 0.0)
    isempty(nz) && return Vector{Vector{Int}}()
    events = Vector{Vector{Int}}()
    cur = [nz[1]]
    for i in 2:length(nz)
        if nz[i] == nz[i-1] + 1
            push!(cur, nz[i])
        else
            push!(events, cur)
            cur = [nz[i]]
        end
    end
    push!(events, cur)
    return events
end

raw_events = cluster_consecutive(sys_shortfall)

println("Total distinct stress events: ", length(raw_events))
println("Mean event duration:          ", round(mean(length.(raw_events)), digits=1), " hours")
println("Max event duration:           ", maximum(length.(raw_events)), " hours")
println("Single-hour events:           ", count(e -> length(e)==1, raw_events))
println("Multi-hour events (≥2h):      ", count(e -> length(e)>=2, raw_events))

# Compute stats for each event
event_rows = []
for (i, ev) in enumerate(raw_events)
    total_eue = sum(sys_shortfall[ev])
    peak_sf   = maximum(sys_shortfall[ev])
    peak_pct  = maximum(sys_shortfall[ev] ./ sys_demand[ev]) * 100.0
    avg_pct   = mean(sys_shortfall[ev]   ./ sys_demand[ev]) * 100.0
    push!(event_rows, (event_id     = i,
                        start_hour   = minimum(ev),
                        end_hour     = maximum(ev),
                        duration_hrs = length(ev),
                        total_eue_mwh= round(total_eue, digits=1),
                        peak_hourly_mwh = round(peak_sf, digits=1),
                        peak_pct_demand = round(peak_pct, digits=2),
                        avg_pct_demand  = round(avg_pct,  digits=2),
                        start_ts     = string(timestamps[minimum(ev)]),
                        end_ts       = string(timestamps[maximum(ev)])))
end

events_df = DataFrame(event_rows)
sort!(events_df, :total_eue_mwh, rev=true)
events_df.rank = 1:nrow(events_df)

top10_events = events_df[1:min(10, nrow(events_df)), :]
CSV.write(joinpath(ROOT, "event_ranking.csv"), events_df)
CSV.write(joinpath(ROOT, "top10_events.csv"),  top10_events)

println("\n--- TOP 10 STRESS EVENTS (by total EUE) ---")
println(rpad("Rank",5), rpad("Start",24), rpad("End",24),
        rpad("Dur(h)",8), rpad("Total EUE MWh",15),
        rpad("Peak MWh/h",12), rpad("Peak%Dem",10), "Avg%Dem")
for row in eachrow(top10_events)
    println(rpad(row.rank,5), rpad(row.start_ts,24), rpad(row.end_ts,24),
            rpad(row.duration_hrs,8), rpad(row.total_eue_mwh,15),
            rpad(row.peak_hourly_mwh,12), rpad(row.peak_pct_demand,10),
            row.avg_pct_demand)
end
println("\n  → Saved event_ranking.csv and top10_events.csv")

# Annotation: map top-10 events back to which top-10 hourly events they contain
println("\n--- HOW TOP-10 HOURLY EVENTS MAP TO STRESS EVENTS ---")
for (rank, t) in enumerate(top10_idx)
    ev_rank = findfirst(row -> row.start_hour <= t <= row.end_hour, eachrow(top10_events))
    if ev_rank !== nothing
        ev = top10_events[ev_rank, :]
        println("  Hourly rank $rank (hour $t) → Stress event rank $(ev.rank): ",
                ev.start_ts, " to ", ev.end_ts,
                " (", ev.duration_hrs, " hrs, total EUE = ", ev.total_eue_mwh, " MWh)")
    end
end

# ============================================================================
# SECTION B: TRANSMISSION CONSTRAINT CLASSIFICATION (ALL SHORTFALL HOURS)
# For every hour with any shortfall, classify WHY the most-deficit zone
# couldn't import enough: is the line itself too small, or are neighbours
# also running short?
# ============================================================================
println("\n" * "="^70)
println("TRANSMISSION CONSTRAINT CLASSIFICATION — ALL SHORTFALL HOURS")
println("="^70)
println("Precomputing per-zone generation availability for all hours...")

# Precompute per-zone hourly available generation (avoids repeated matrix scans)
zone_gen = Dict{String, Vector{Float64}}()
for region in region_names
    mask = String.(pras_generators.bus) .== region
    zone_gen[region] = any(mask) ? vec(sum(gen_capacity[mask, :], dims=1)) :
                                    zeros(Float64, N_HOURS)
end
println("  Done. Classifying ", count(>(0.0), sys_shortfall), " non-zero shortfall hours...")

constraint_rows = []
type_counts = Dict("Line capacity binding"     => 0,
                   "Neighbour capacity binding" => 0,
                   "Partially covered"          => 0,
                   "Transmission can cover"     => 0)

for t in findall(sys_shortfall .> 0.0)
    # Zone with the largest shortfall at this hour drives the classification
    r_max    = argmax(shortfall_mat[:, t])
    zone_max = sorted_regs[r_max]
    sf_max   = shortfall_mat[r_max, t]

    # Lines connecting this zone
    connected = filter(row -> strip(String(row.bus0)) == zone_max ||
                               strip(String(row.bus1)) == zone_max, internal_links)

    total_line_cap   = sum(Float64.(connected.p_nom))
    total_importable = 0.0

    for row in eachrow(connected)
        nb = strip(String(row.bus0)) == zone_max ?
             strip(String(row.bus1)) : strip(String(row.bus0))
        ni = findfirst(==(nb), region_names)
        ni === nothing && continue

        nb_avail   = get(zone_gen, nb, zeros(N_HOURS))[t]
        nb_dem     = load_matrix[ni, t]
        nb_csv     = findfirst(==(nb), sorted_regs)
        nb_sfx     = nb_csv !== nothing ? shortfall_mat[nb_csv, t] : 0.0
        nb_surplus = max(0.0, nb_avail - nb_dem - nb_sfx)
        total_importable += min(Float64(row.p_nom), nb_surplus)
    end

    ctype = if total_line_cap < sf_max * 0.5
        "Line capacity binding"
    elseif total_importable < sf_max * 0.5
        "Neighbour capacity binding"
    elseif total_importable < sf_max
        "Partially covered"
    else
        "Transmission can cover"
    end

    type_counts[ctype] += 1
    push!(constraint_rows, (hour        = t,
                             zone        = zone_max,
                             shortfall   = round(sf_max, digits=1),
                             line_cap    = round(total_line_cap, digits=0),
                             importable  = round(total_importable, digits=0),
                             constraint  = ctype))
end

constraint_df = DataFrame(constraint_rows)
CSV.write(joinpath(ROOT, "transmission_constraint_all_hours.csv"), constraint_df)

total_classified = sum(values(type_counts))
println("\n--- TRANSMISSION CONSTRAINT CLASSIFICATION (all shortfall hours) ---")
for (ctype, cnt) in sort(collect(type_counts), by=x->-x[2])
    pct = round(100*cnt/total_classified, digits=1)
    bar = "█" ^ round(Int, pct/2)
    println("  ", rpad(ctype,30), rpad(cnt,7), " hrs  (", rpad(pct,5), "%)  $bar")
end

# Save summary counts for MATLAB
counts_df = DataFrame(
    constraint_type = collect(keys(type_counts)),
    hours           = collect(values(type_counts)),
    pct             = [round(100*v/total_classified, digits=2)
                       for v in values(type_counts)]
)
sort!(counts_df, :hours, rev=true)
CSV.write(joinpath(ROOT, "transmission_constraint_summary.csv"), counts_df)
println("\n  → Saved transmission_constraint_all_hours.csv")
println("  → Saved transmission_constraint_summary.csv")

println("\n" * "="^70)
println("DONE — load CSV files into MATLAB for visualisation.")
println("="^70)

