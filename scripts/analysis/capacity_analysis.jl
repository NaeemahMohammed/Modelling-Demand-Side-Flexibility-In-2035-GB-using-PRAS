#!/usr/bin/env julia
# =============================================================================
# capacity_analysis.jl
#
# Run in the SAME Julia session as the build script (gen_capacity, gen_names,
# gen_categories, pras_generators, region_names, load_matrix, N_HOURS, ROOT
# must all be in scope).
#
# Computes for wind and solar generators:
#   - Installed (nameplate) capacity MW
#   - Annual generation GWh
#   - Annual capacity factor %
#   - Peak generation MW
# Broken down by: carrier, offshore vs onshore wind, and per zone.
# Also reports thermal installed capacity (no dispatch CF available without
# Flow results — that requires re-running PRAS; see flow_availability_analysis.jl).
#
# Exports: capacity_factor_analysis.csv
# =============================================================================

using CSV, DataFrames, Statistics

println("\n" * "="^70)
println("CAPACITY FACTOR AND GENERATION ANALYSIS")
println("="^70)

# Carrier groups
VARIABLE   = Set(["wind_onshore","wind_offshore","solar_pv","embedded_wind","embedded_solar"])
WIND_ON    = Set(["wind_onshore","embedded_wind"])
WIND_OFF   = Set(["wind_offshore"])
SOLAR      = Set(["solar_pv","embedded_solar"])
FIRM       = Set(["CCGT","OCGT","nuclear","biomass","coal","oil","landfill_gas",
                   "biogas","sewage_gas","advanced_biofuel","waste_to_energy",
                   "CHP","gas_engine","H2_turbine","geothermal","marine",
                   "tidal_stream","shoreline_wave","small_hydro","large_hydro"])

# ── Helper: compute stats for a boolean mask over generators ─────────────────
function gen_stats(mask)
    any(mask)      || return (nameplate=0.0, annual_gwh=0.0, peak_mw=0.0, cf_pct=0.0)
    nameplate       = sum(pras_generators.p_nom[mask])
    nameplate == 0  && return (nameplate=0.0, annual_gwh=0.0, peak_mw=0.0, cf_pct=0.0)
    hourly_mw       = vec(sum(gen_capacity[mask, :], dims=1))   # sum across generators, per hour
    annual_mwh      = sum(hourly_mw)
    peak_mw         = maximum(hourly_mw)
    cf_pct          = 100.0 * (annual_mwh / N_HOURS) / nameplate
    return (nameplate=nameplate, annual_gwh=annual_mwh/1000, peak_mw=peak_mw, cf_pct=cf_pct)
end

# ============================================================================
# 1. DEMAND CONTEXT
# ============================================================================
total_demand_mwh = sum(load_matrix)
peak_demand_mw   = maximum(vec(sum(load_matrix, dims=1)))
println("\n--- DEMAND CONTEXT ---")
println("Peak system demand:   ", round(Int, peak_demand_mw), " MW")
println("Total annual demand:  ", round(total_demand_mwh/1e6, digits=3), " TWh")

# ============================================================================
# 2. SYSTEM-LEVEL CAPACITY FACTOR GROUPS
# ============================================================================
println("\n--- SYSTEM-LEVEL GROUPS ---")
println(rpad("Group",32), rpad("Installed MW",14), rpad("Annual GWh",13),
        rpad("Peak MW",10), "Mean CF%")

groups = [
    ("All variable renewables",     [gen_categories[i] in VARIABLE  for i in eachindex(gen_categories)]),
    ("Wind (all)",                   [gen_categories[i] in union(WIND_ON,WIND_OFF) for i in eachindex(gen_categories)]),
    ("  Wind onshore + embedded",   [gen_categories[i] in WIND_ON   for i in eachindex(gen_categories)]),
    ("  Wind offshore",             [gen_categories[i] in WIND_OFF  for i in eachindex(gen_categories)]),
    ("Solar PV + embedded",         [gen_categories[i] in SOLAR     for i in eachindex(gen_categories)]),
]

cf_rows = []
for (label, mask) in groups
    s = gen_stats(BitVector(mask))
    println(rpad(label,32), rpad(round(Int,s.nameplate),14),
            rpad(round(s.annual_gwh,digits=1),13),
            rpad(round(Int,s.peak_mw),10),
            round(s.cf_pct, digits=1), "%")
    push!(cf_rows, (group=label, installed_mw=round(Int,s.nameplate),
                    annual_gwh=round(s.annual_gwh,digits=1),
                    peak_mw=round(Int,s.peak_mw),
                    mean_cf_pct=round(s.cf_pct,digits=2)))
end

# ============================================================================
# 3. BY INDIVIDUAL CARRIER
# ============================================================================
println("\n--- BY CARRIER ---")
println(rpad("Carrier",28), rpad("N gens",8), rpad("Installed MW",14),
        rpad("Annual GWh",13), rpad("Peak MW",10), "Mean CF%")

all_carriers = unique(gen_categories)
for c in sort(all_carriers)
    mask = gen_categories .== c
    s    = gen_stats(mask)
    s.nameplate == 0 && continue
    is_var = c in VARIABLE
    cf_str = is_var ? "$(round(s.cf_pct,digits=1))%" :
                      "$(round(s.cf_pct,digits=1))% (available — dispatch CF n/a)"
    println(rpad(c,28), rpad(count(mask),8), rpad(round(Int,s.nameplate),14),
            rpad(is_var ? round(s.annual_gwh,digits=1) : "n/a",13),
            rpad(is_var ? round(Int,s.peak_mw) : "n/a",10),
            cf_str)
    push!(cf_rows, (group=c, installed_mw=round(Int,s.nameplate),
                    annual_gwh=is_var ? round(s.annual_gwh,digits=1) : -1.0,
                    peak_mw=is_var ? round(Int,s.peak_mw) : -1,
                    mean_cf_pct=round(s.cf_pct,digits=2)))
end

# ============================================================================
# 4. PER ZONE — VARIABLE RENEWABLES ONLY
# ============================================================================
println("\n--- VARIABLE RENEWABLE CF BY ZONE ---")
println(rpad("Zone",10), rpad("Installed MW",14), rpad("Annual GWh",13),
        rpad("Peak MW",10), rpad("Mean CF%",10),
        rpad("Wind on MW",12), rpad("Wind off MW",13), "Solar MW")

function zone_sort_key(name)
    m = match(r"^Z(\d+)(?:_(\d+))?$", name)
    m === nothing && return (typemax(Int), typemax(Int))
    (parse(Int,m[1]), m[2]===nothing ? 0 : parse(Int,m[2]))
end

zone_cf_rows = []
for region in sort(region_names, by=zone_sort_key)
    mask_all = BitVector([gen_categories[i] in VARIABLE && String(pras_generators.bus[i]) == region
                          for i in eachindex(gen_categories)])
    s = gen_stats(mask_all)
    s.nameplate == 0 && continue

    mask_won = BitVector([gen_categories[i] in WIND_ON  && String(pras_generators.bus[i]) == region for i in eachindex(gen_categories)])
    mask_wof = BitVector([gen_categories[i] in WIND_OFF && String(pras_generators.bus[i]) == region for i in eachindex(gen_categories)])
    mask_sol = BitVector([gen_categories[i] in SOLAR    && String(pras_generators.bus[i]) == region for i in eachindex(gen_categories)])
    s_won = gen_stats(mask_won); s_wof = gen_stats(mask_wof); s_sol = gen_stats(mask_sol)

    println(rpad(region,10), rpad(round(Int,s.nameplate),14),
            rpad(round(s.annual_gwh,digits=1),13),
            rpad(round(Int,s.peak_mw),10),
            rpad(string(round(s.cf_pct,digits=1))*"%",10),
            rpad(round(Int,s_won.nameplate),12),
            rpad(round(Int,s_wof.nameplate),13),
            round(Int,s_sol.nameplate))

    push!(zone_cf_rows, (zone=region,
                          total_variable_mw     = round(Int,s.nameplate),
                          annual_gwh            = round(s.annual_gwh,digits=1),
                          peak_mw               = round(Int,s.peak_mw),
                          mean_cf_pct           = round(s.cf_pct,digits=2),
                          wind_onshore_mw       = round(Int,s_won.nameplate),
                          wind_offshore_mw      = round(Int,s_wof.nameplate),
                          solar_mw              = round(Int,s_sol.nameplate),
                          wind_on_cf_pct        = round(s_won.cf_pct,digits=2),
                          wind_off_cf_pct       = round(s_wof.cf_pct,digits=2),
                          solar_cf_pct          = round(s_sol.cf_pct,digits=2)))
end

# ============================================================================
# 5. FIRM CAPACITY SUMMARY (no dispatch CF — PRAS doesn't report dispatch)
# ============================================================================
println("\n--- FIRM / THERMAL CAPACITY (dispatch CF requires Flow results) ---")
println(rpad("Carrier",28), rpad("N gens",8), "Installed MW")
function print_firm_capacity()
    total = 0.0
    for c in sort(collect(FIRM))
        mask = gen_categories .== c
        any(mask) || continue
        mw = sum(pras_generators.p_nom[mask])
        mw == 0 && continue
        println(rpad(c,28), rpad(count(mask),8), round(Int,mw))
        total += mw
    end
    println(rpad("TOTAL FIRM",28), rpad("",8), round(Int,total))
end
print_firm_capacity()

# ============================================================================
# 6. SAVE
# ============================================================================
CSV.write(joinpath(ROOT, "capacity_factor_analysis.csv"),    DataFrame(cf_rows))
CSV.write(joinpath(ROOT, "capacity_factor_by_zone.csv"),     DataFrame(zone_cf_rows))
println("\n  → Saved capacity_factor_analysis.csv")
println("  → Saved capacity_factor_by_zone.csv")

println("\n" * "="^70)
println("DONE — run flow_availability_analysis.jl next for PRAS result specs")
println("="^70)
