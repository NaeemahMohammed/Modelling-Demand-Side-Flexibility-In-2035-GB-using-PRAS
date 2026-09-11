#!/usr/bin/env julia
# =============================================================================
# build_gb_pras_system2035.jl
#
# 2035 Holistic Transition (weather year 2020) build, derived from
# build_gb_pras_system.jl (the 2024 version). Differences from that version,
# so nothing here is silently different:
#
#   1. N_HOURS = 8760, not 8784 -- PyPSA-GB's convention drops the leap day
#      rather than using true 2020 calendar hours (2020 is a real leap year,
#      366 days = 8784 hours). Timestamps are built from N_HOURS directly
#      (start + N_HOURS-1 hours) rather than a hardcoded year-end date, so
#      they can't silently disagree with N_HOURS again.
#
#   2. PROJECT ROOT is hardcoded to the GBReliability2035 folder rather than
#      using @__DIR__ -- less portable, but simpler for this fixed location.
#
#   3. Link filtering no longer checks for the literal string
#      "HVDC_External" -- 2035 introduces a hydrogen-sector bus (GB_H2) that
#      isn't an HVDC interconnector but is equally out of scope for an
#      electricity-only Lines/Interfaces model. Links are now kept only if
#      BOTH ends are in the GB region set, catching any future out-of-scope
#      bus automatically.
#
#   4. HYDROGEN SYSTEM modelled as a PRAS StorageUnit at GB_H2:
#      - Charge (electrolysis, zone→GB_H2 Lines): 7,426 MW at efficiency 0.70
#      - Discharge (H2 turbines, GB_H2→zone Lines): ~1,960 MW at efficiency 0.50
#      - Energy capacity: 658,421 MWh (from PyPSA-GB documentation)
#      - Inflow = 0 (hydrogen production optimised in PyPSA; PRAS charges only
#        when surplus exists in the zone, via the Line interfaces)
#      - Electrolysis is NO LONGER added as fixed demand on zones
#      - H2 turbine links are asymmetric Lines: forward (zone→GB_H2) = 0,
#        backward (GB_H2→zone) = electrical output. Electrolysis links are the
#        reverse: forward (zone→GB_H2) = p_nom, backward = 0. Together the
#        interface has charge capacity = 7,426 MW and discharge = 1,960 MW.
#
#   5. New generator carriers not present in the 2024 generator_reliability.csv
#      need placeholder MTTF/MTTR rows added to that CSV by hand:
#        marine,1000000,1
#        CHP,2500,120
#        gas_engine,2500,120
#        geothermal,2500,120
#        H2_turbine,2000,120
#
# Everything else (storage, the load_shedding drop, weather-profile wiring,
# the n_regional scope fix) is unchanged from the 2024 version.
# =============================================================================

using CSV
using DataFrames
using Dates
using TimeZones
using PRAS
using Serialization
using Statistics

# -----------------------------------------------------------------------------
# 0. PROJECT ROOT
# -----------------------------------------------------------------------------
const ROOT = const ROOT = raw"C:\Users\nam125\OneDrive - Imperial College London\Desktop\Individual Research Project\GBReliability2035DR"
datapath(f) = joinpath(ROOT, "data", f)

println("=== Loading raw data ===")

buses_df       = CSV.read(datapath("buses.csv"), DataFrame)
links_df       = CSV.read(datapath("links.csv"), DataFrame)
gen_static_df  = CSV.read(datapath("generators_static.csv"), DataFrame)
reliability_df = CSV.read(datapath("generator_reliability.csv"), DataFrame)
storage_df     = CSV.read(datapath("storage_static.csv"), DataFrame)
loads_pset_df  = CSV.read(datapath("loads_p_set.csv"), DataFrame)

# N_HOURS and WEATHER_YEAR are read straight from the data, not hardcoded --
# this is the 3rd time a manually-copied constant has silently mismatched
# across a weather-year folder, so it's no longer a constant at all.
const N_HOURS = nrow(loads_pset_df)
year_match = match(r"(\d{4})", string(loads_pset_df.snapshot[1]))
year_match === nothing && error("Couldn't detect a 4-digit year in loads_p_set.csv's first snapshot: $(loads_pset_df.snapshot[1])")
const WEATHER_YEAR = parse(Int, year_match.captures[1])
println("  Detected from data: N_HOURS = $N_HOURS, WEATHER_YEAR = $WEATHER_YEAR")

open(joinpath(ROOT, "run_metadata.txt"), "w") do io
    println(io, N_HOURS)
    println(io, WEATHER_YEAR)
end

# -----------------------------------------------------------------------------
# 1. GENERATORS -- join the individual-generator register against carrier-
#    level reliability stats, save a pras_generators.csv checkpoint.
# -----------------------------------------------------------------------------
println("=== Building generator table ===")

required_gen_cols = ["name", "bus", "carrier", "p_nom"]
missing_cols = setdiff(required_gen_cols, names(gen_static_df))
isempty(missing_cols) || error(
    "generators_static.csv is missing column(s): $missing_cols. " *
    "Expected at least: $required_gen_cols")

gen_rel = leftjoin(gen_static_df, reliability_df, on=:carrier)

n_missing_reliability = sum(ismissing, gen_rel.MTTF_hours)
if n_missing_reliability > 0
    bad_carriers = unique(gen_rel.carrier[ismissing.(gen_rel.MTTF_hours)])
    error("No reliability data for carrier(s): $bad_carriers -- add them to generator_reliability.csv")
end

gen_rel.FOR = gen_rel.MTTR_hours ./ (gen_rel.MTTF_hours .+ gen_rel.MTTR_hours)

pras_generators = select(gen_rel, :name, :bus, :carrier, :p_nom, :FOR, :MTTF_hours, :MTTR_hours)

CSV.write(datapath("pras_generators.csv"), pras_generators)
println("  Wrote ", datapath("pras_generators.csv"), " (", nrow(pras_generators), " generators, before region filtering)")

# -----------------------------------------------------------------------------
# 2. REGIONS -- GB zones only, real hourly load.
#    Electrolysis is NO LONGER added as fixed load -- it is now modelled
#    as the charge side of a StorageUnit at GB_H2 (see storage section).
# -----------------------------------------------------------------------------
# -----------------------------------------------------------------------------
println("=== Building regions ===")

gb_buses = filter(row -> startswith(strip(row.name), "Z"), buses_df)
region_names = strip.(String.(gb_buses.name))
n_regions = length(region_names)
region_index = Dict(name => i for (i, name) in enumerate(region_names))

load_col_for(region) = "load_" * region
missing_load_cols = [region_names[i] for i in 1:n_regions
                      if !(load_col_for(region_names[i]) in names(loads_pset_df))]
isempty(missing_load_cols) || error("loads_p_set.csv has no column for region(s): $missing_load_cols")

load_matrix = Matrix{Int}(undef, n_regions, N_HOURS)
for (i, region) in enumerate(region_names)
    col = loads_pset_df[!, load_col_for(region)]
    length(col) == N_HOURS || error("loads_p_set.csv column '$(load_col_for(region))' has $(length(col)) rows, expected $N_HOURS")
    load_matrix[i, :] = round.(Int, col)
end

# Electrolysis demand -- see limitation #4 in the header comment.
electrolysis_links = filter(row -> row.bus1 == "GB_H2", links_df)
println("  Note: ", nrow(electrolysis_links), " electrolysis links (", round(sum(electrolysis_links.p_nom), digits=1),
        " MW) modelled as StorageUnit charge capacity at GB_H2, not as fixed load.")

# Add GB_H2 as a 21st region — a notional hydrogen storage/routing hub.
# It carries zero electrical load; the H2 turbine links become PRAS Lines
# connecting it to the destination zones (see lines section below).
push!(region_names, "GB_H2")
n_regions = length(region_names)
region_index["GB_H2"] = n_regions
load_matrix = vcat(load_matrix, zeros(Int, 1, N_HOURS))
println("  Added GB_H2 as region $n_regions (hydrogen hub, zero electrical load)")

regions = PRAS.Regions{N_HOURS, MW}(region_names, load_matrix)

println("  $n_regions regions, peak combined load = ", maximum(vec(sum(load_matrix, dims=1))), " MW")

# -----------------------------------------------------------------------------
# 3. GENERATORS -> PRAS.Generators, grouped contiguously by region.
# -----------------------------------------------------------------------------
println("=== Building PRAS generators ===")

gen_bus_clean = strip.(String.(pras_generators.bus))
region_set = Set(region_names)   # now includes GB_H2
n_before = nrow(pras_generators)
keep = [b in region_set for b in gen_bus_clean]
dropped_buses = unique(gen_bus_clean[.!keep])
pras_generators = pras_generators[keep, :]
pras_generators.bus = gen_bus_clean[keep]
println("  Dropped $(n_before - nrow(pras_generators)) generator(s) outside the $n_regions GB regions: ", dropped_buses)

ls_capacity = sum(pras_generators.p_nom[pras_generators.carrier .== "load_shedding"])
n_before_ls = nrow(pras_generators)
pras_generators = filter(row -> row.carrier != "load_shedding", pras_generators)
println("  Dropped $(n_before_ls - nrow(pras_generators)) load_shedding generator(s) totalling ",
        round(ls_capacity, digits=1), " MW (not a real supply resource)")

# H2 turbine links and reliability -- needed for Lines and GB_H2 StorageUnit.
# The individual turbines are now PRAS Lines (GB_H2 <-> zone) not generators.
h2_turbine_links    = filter(row -> row.bus0 == "GB_H2", links_df)
h2_electrical_total = sum(Float64.(h2_turbine_links.p_nom) .* Float64.(h2_turbine_links.efficiency))
h2_rel_row = filter(row -> row.carrier == "H2_turbine", reliability_df)
isempty(h2_rel_row) && error("No reliability data for H2_turbine -- add it to generator_reliability.csv")
h2_mttf = Float64(h2_rel_row.MTTF_hours[1])
h2_mttr = Float64(h2_rel_row.MTTR_hours[1])
println("  H2 system: ", nrow(h2_turbine_links), " turbines (", round(h2_electrical_total, digits=1),
        " MW electrical) modelled as Lines + StorageUnit, not as generators.")

sort_perm = sortperm(pras_generators.bus, by = b -> region_index[b])
pras_generators = pras_generators[sort_perm, :]

gen_names      = Vector{String}(pras_generators.name)
gen_categories = Vector{String}(pras_generators.carrier)
gen_capacity   = repeat(reshape(round.(Int, pras_generators.p_nom), :, 1), 1, N_HOURS)
gen_lambda     = repeat(reshape(1.0 ./ Float64.(pras_generators.MTTF_hours), :, 1), 1, N_HOURS)
gen_mu         = repeat(reshape(1.0 ./ Float64.(pras_generators.MTTR_hours), :, 1), 1, N_HOURS)

has_profile = falses(length(gen_names))

gen_pmax_pu_path = datapath("generators_p_max_pu.csv")
if isfile(gen_pmax_pu_path)
    gen_ts = CSV.read(gen_pmax_pu_path, DataFrame)
    nrow(gen_ts) == N_HOURS || error(
        "generators_p_max_pu.csv has $(nrow(gen_ts)) rows, expected $N_HOURS -- " *
        "check it covers the same period as loads_p_set.csv")

    profile_cols = Set(names(gen_ts)[2:end])
    for (i, name) in enumerate(gen_names)
        if name in profile_cols
            gen_capacity[i, :] .= round.(Int, pras_generators.p_nom[i] .* gen_ts[!, name])
            has_profile[i] = true
        end
    end
    println("  Applied per-farm weather profile to $(count(has_profile)) of $(length(gen_names)) generators")
else
    println("  generators_p_max_pu.csv not found at $gen_pmax_pu_path -- skipping per-farm profiles")
end

renewables_cf_path = datapath("renewables_cf_by_region.csv")
if isfile(renewables_cf_path)
    cf_lines = readlines(renewables_cf_path)
    cf_bus_row     = split(cf_lines[1], ',')[2:end]
    cf_carrier_row = split(cf_lines[2], ',')[2:end]
    cf_data_lines = cf_lines[4:end]
    length(cf_data_lines) == N_HOURS || error(
        "renewables_cf_by_region.csv has $(length(cf_data_lines)) data rows, expected $N_HOURS")

    cf = Dict{Tuple{String,String},Vector{Float64}}()
    for j in eachindex(cf_bus_row)
        col = Vector{Float64}(undef, N_HOURS)
        for (i, line) in enumerate(cf_data_lines)
            col[i] = parse(Float64, split(line, ',')[j+1])
        end
        cf[(cf_bus_row[j], cf_carrier_row[j])] = col
    end

    n_regional = 0
    for (i, name) in enumerate(gen_names)
        if !has_profile[i]
            key = (pras_generators.bus[i], gen_categories[i])
            if haskey(cf, key)
                gen_capacity[i, :] .= round.(Int, pras_generators.p_nom[i] .* cf[key])
                has_profile[i] = true
                global n_regional += 1
            end
        end
    end
    println("  Applied regional capacity factor to a further $n_regional generators")
else
    println("  renewables_cf_by_region.csv not found at $renewables_cf_path -- skipping regional fallback")
end

println("  $(length(gen_names) - count(has_profile)) generators have no weather profile and stay at flat nameplate capacity")

function embed_vres_for!(gen_capacity, gen_categories, indiv_for)
    n = 0
    for i in eachindex(gen_categories)
        c = gen_categories[i]
        if haskey(indiv_for, c)
            gen_capacity[i, :] .= round.(Int, gen_capacity[i, :] .* (1.0 - indiv_for[c]))
            n += 1
        end
    end
    return n
end

const INDIV_FOR = Dict(
    "wind_offshore"  => 0.030,
    "wind_onshore"   => 0.014,
    "embedded_wind"  => 0.014,
    "solar_pv"       => 0.010,
    "embedded_solar" => 0.010,
)
n_for_embedded = embed_vres_for!(gen_capacity, gen_categories, INDIV_FOR)
println("  Embedded individual unit FOR into capacity factors for $n_for_embedded variable RES generators")

gens = PRAS.Generators{N_HOURS,1,Hour,MW}(
    gen_names, gen_categories, gen_capacity, gen_lambda, gen_mu,
)

region_gen_idxs = Vector{UnitRange{Int}}(undef, n_regions)
let pos = 1
    for (i, region) in enumerate(region_names)
        n = count(==(region), pras_generators.bus)
        region_gen_idxs[i] = n > 0 ? (pos:(pos + n - 1)) : (pos:(pos - 1))
        pos += n
    end
end

@assert sum(length, region_gen_idxs) == length(gens) "region_gen_idxs doesn't cover all generators"
println("  $(length(gens)) generators across $n_regions regions")

# -----------------------------------------------------------------------------
# 4. STORAGE -- batteries + pumped hydro from storage_static.csv.
# -----------------------------------------------------------------------------
println("=== Building storage ===")

required_stor_cols = ["name", "bus", "carrier", "p_nom", "max_hours",
                       "efficiency_store", "efficiency_dispatch", "standing_loss"]
missing_cols = setdiff(required_stor_cols, names(storage_df))
isempty(missing_cols) || error("storage_static.csv is missing column(s): $missing_cols")

storage_df.bus = strip.(String.(storage_df.bus))
n_before_stor = nrow(storage_df)
stor_keep = [b in region_set for b in storage_df.bus]
dropped_stor_buses = unique(storage_df.bus[.!stor_keep])
storage_df = storage_df[stor_keep, :]
if n_before_stor != nrow(storage_df)
    println("  Dropped $(n_before_stor - nrow(storage_df)) storage unit(s) outside the $n_regions GB regions: ", dropped_stor_buses)
end

sort_perm = sortperm(storage_df.bus, by = b -> region_index[b])
storage_df = storage_df[sort_perm, :]

stor_names         = String.(storage_df.name)
stor_categories    = String.(storage_df.carrier)
stor_charge_cap    = repeat(reshape(round.(Int, storage_df.p_nom), :, 1), 1, N_HOURS)
stor_discharge_cap = copy(stor_charge_cap)
stor_energy_cap    = repeat(reshape(round.(Int, storage_df.p_nom .* storage_df.max_hours), :, 1), 1, N_HOURS)
stor_charge_eff    = repeat(reshape(Float64.(storage_df.efficiency_store),    :, 1), 1, N_HOURS)
stor_discharge_eff = repeat(reshape(Float64.(storage_df.efficiency_dispatch), :, 1), 1, N_HOURS)
stor_carryover_eff = repeat(reshape(1.0 .- Float64.(storage_df.standing_loss), :, 1), 1, N_HOURS)

n_stor      = nrow(storage_df)
stor_lambda = fill(1.0 / 1_000_000.0, n_stor, N_HOURS)
stor_mu     = fill(1.0, n_stor, N_HOURS)

println("  $(nrow(storage_df)) conventional storage units across $(n_regions - 1) GB zones")

region_stor_idxs = Vector{UnitRange{Int}}(undef, n_regions)
let pos = 1
    for (i, region) in enumerate(region_names)
        n = count(==(region), storage_df.bus)
        region_stor_idxs[i] = n > 0 ? (pos:(pos + n - 1)) : (pos:(pos - 1))
        pos += n
    end
    region_stor_idxs[n_regions] = (n_stor + 1):(n_stor + 1)  # placeholder for GB_H2
end

# -----------------------------------------------------------------------------
# 5. GB_H2 STORAGE -- models the coupled electrolysis + H2 turbine system
#    as a single Storage object at the GB_H2 region.
#
#    Parameters from PyPSA-GB data:
#      charge_capacity    = sum of electrolysis p_nom       = 7,426 MW
#      discharge_capacity = sum of H2 turbine electrical    = p_nom × efficiency
#      energy_capacity    = H2 storage nominal energy       = 658,421 MWh
#      charge_efficiency  = electrolysis efficiency         = 0.70
#      discharge_efficiency = H2 turbine efficiency         = 0.50
#      carryover_efficiency = ~1.0 (hydrogen minimal loss)
#      inflow             = 0 (optimised flow in PyPSA, modelled as grid-charged here)
#
#    Round-trip efficiency: 0.70 × 0.50 = 0.35
#    NESO FES 2025 Table F17: H2 storage duration = 120 hours.
#    Required discharge cap = energy × discharge_eff / 120h
#    = 658,421 × 0.50 / 120 = 2,743 MW  (PyPSA-GB implied 1,960 MW → corrected)
# -----------------------------------------------------------------------------
println("=== Building GB_H2 hydrogen storage ===")

h2_elec_total           = sum(Float64.(electrolysis_links.p_nom))
const H2_ENERGY_CAPACITY_MWH = 658_421.064   # from PyPSA-GB H2 storage nominal energy
const H2_DURATION_HRS   = 120                 # NESO FES 2025 Table F17
const H2_DISCHARGE_CAP_MW = round(Int, H2_ENERGY_CAPACITY_MWH * 0.50 / H2_DURATION_HRS)
const H2_TURB_SCALE     = H2_DISCHARGE_CAP_MW / h2_electrical_total

h2_stor_names      = ["GB_H2_storage"]
h2_stor_categories = ["H2_storage"]
h2_charge_cap      = fill(round(Int, h2_elec_total),       1, N_HOURS)
h2_discharge_cap   = fill(H2_DISCHARGE_CAP_MW,             1, N_HOURS)
h2_energy_cap      = fill(round(Int, H2_ENERGY_CAPACITY_MWH), 1, N_HOURS)
h2_charge_eff      = fill(0.70, 1, N_HOURS)
h2_discharge_eff   = fill(0.50, 1, N_HOURS)
h2_carryover_eff   = fill(1.0,  1, N_HOURS)
h2_lambda          = fill(clamp(1.0 / h2_mttf, 0.0, 1.0), 1, N_HOURS)
h2_mu              = fill(clamp(1.0 / h2_mttr, 0.0, 1.0), 1, N_HOURS)

println("  GB_H2 storage: charge=", round(h2_elec_total, digits=1),
        " MW, discharge=", H2_DISCHARGE_CAP_MW,
        " MW (NESO 120h target), energy=",
        round(H2_ENERGY_CAPACITY_MWH/1000, digits=1), " GWh")
println("  Duration check: ", round(H2_ENERGY_CAPACITY_MWH*0.50/H2_DISCHARGE_CAP_MW, digits=1),
        " h (target: ", H2_DURATION_HRS, " h)")

# Append GB_H2 storage to existing arrays
stor_names         = vcat(stor_names,         h2_stor_names)
stor_categories    = vcat(stor_categories,    h2_stor_categories)
stor_charge_cap    = vcat(stor_charge_cap,    h2_charge_cap)
stor_discharge_cap = vcat(stor_discharge_cap, h2_discharge_cap)
stor_energy_cap    = vcat(stor_energy_cap,    h2_energy_cap)
stor_charge_eff    = vcat(stor_charge_eff,    h2_charge_eff)
stor_discharge_eff = vcat(stor_discharge_eff, h2_discharge_eff)
stor_carryover_eff = vcat(stor_carryover_eff, h2_carryover_eff)
stor_lambda        = vcat(stor_lambda,        h2_lambda)
stor_mu            = vcat(stor_mu,            h2_mu)

# Fix GB_H2 storage index now that we know the final array length
region_stor_idxs[region_index["GB_H2"]] = length(stor_names):length(stor_names)

storages = PRAS.Storages{N_HOURS,1,Hour,MW,MWh}(
    stor_names, stor_categories,
    stor_charge_cap, stor_discharge_cap, stor_energy_cap,
    stor_charge_eff, stor_discharge_eff, stor_carryover_eff,
    stor_lambda, stor_mu,
)

@assert sum(length, region_stor_idxs) == length(storages) "region_stor_idxs doesn't cover all storages"
println("  Total storage: $(length(storages)) units (including GB_H2)")

generatorstorages   = PRAS.GeneratorStorages{N_HOURS,1,Hour,MW,MWh}()
region_genstor_idxs = [1:0 for _ in 1:n_regions]
include(joinpath(ROOT, "demand_response.jl"))

# -----------------------------------------------------------------------------
# 6. LINES + INTERFACES
#    - AC/DC zone links: symmetric capacity = p_nom
#    - H2 turbine links (GB_H2 → zone): after canonicalization (zone < GB_H2)
#      these become backward (GB_H2→zone) = p_nom × efficiency, forward = 0
#    - Electrolysis links (zone → GB_H2): after canonicalization
#      these become forward (zone→GB_H2) = p_nom, backward = 0
#    Combined, each zone ↔ GB_H2 interface has:
#      forward (zone→GB_H2) = electrolysis capacity  [charging path]
#      backward (GB_H2→zone) = turbine electrical capacity  [discharging path]
# -----------------------------------------------------------------------------
println("=== Building lines and interfaces ===")

link_bus0_clean = strip.(String.(links_df.bus0))
link_bus1_clean = strip.(String.(links_df.bus1))
link_carrier    = String.(links_df.carrier)

# Include electrolysis links now (they become the charging Lines for GB_H2)
# Only drop external HVDC interconnectors (bus not in region_set)
keep_link = [(b0 in region_set) && (b1 in region_set)
             for (b0, b1) in zip(link_bus0_clean, link_bus1_clean)]
dropped_link_buses = unique(vcat(link_bus0_clean[.!keep_link], link_bus1_clean[.!keep_link]))
internal_links = links_df[keep_link, :]
n_dropped   = nrow(links_df) - nrow(internal_links)
n_h2_lines  = count(c -> c == "H2_turbine",  String.(internal_links.carrier))
n_elec_lines= count(c -> c == "electrolysis", String.(internal_links.carrier))
n_ac_dc     = nrow(internal_links) - n_h2_lines - n_elec_lines
println("  Dropped $n_dropped link(s); $(nrow(internal_links)) internal lines remain ",
        "($n_h2_lines H2 turbine + $n_elec_lines electrolysis + $n_ac_dc AC/DC)")

link_bus0 = link_bus0_clean[keep_link]
link_bus1 = link_bus1_clean[keep_link]

from_idx   = [region_index[b] for b in link_bus0]
to_idx     = [region_index[b] for b in link_bus1]
canon_from = min.(from_idx, to_idx)
canon_to   = max.(from_idx, to_idx)

# Asymmetric forward/backward based on carrier + canonicalization direction
line_forward_vec  = Vector{Int}(undef, nrow(internal_links))
line_backward_vec = Vector{Int}(undef, nrow(internal_links))

for (i, row) in enumerate(eachrow(internal_links))
    c = String(row.carrier)
    if c == "H2_turbine"
        # Original: GB_H2(21) → zone → swapped in canonicalization
        # canonical forward = zone→GB_H2 = 0 (not the turbine direction)
        # canonical backward = GB_H2→zone = electrical output
        line_forward_vec[i]  = 0
        # Scale backward cap to match NESO 120h duration target
        line_backward_vec[i] = round(Int, row.p_nom * row.efficiency * H2_TURB_SCALE)
    elseif c == "electrolysis"
        # Original: zone → GB_H2 → not swapped (zone index < 21)
        # canonical forward = zone→GB_H2 = electrolysis p_nom (charging direction)
        # canonical backward = GB_H2→zone = 0
        line_forward_vec[i]  = round(Int, row.p_nom)
        line_backward_vec[i] = 0
    else
        # AC/DC: symmetric
        line_forward_vec[i]  = round(Int, row.p_nom)
        line_backward_vec[i] = round(Int, row.p_nom)
    end
end

line_forward  = repeat(reshape(line_forward_vec,  :, 1), 1, N_HOURS)
line_backward = repeat(reshape(line_backward_vec, :, 1), 1, N_HOURS)

line_names      = String.(internal_links.name)
line_categories = [c == "H2_turbine" ? "H2_turbine" : (c == "electrolysis" ? "Electrolysis" : "Transmission")
                   for c in String.(internal_links.carrier)]

lambda_vec = [c == "H2_turbine" ? (1.0 / h2_mttf) : 1e-6
              for c in String.(internal_links.carrier)]
mu_vec     = [c == "H2_turbine" ? (1.0 / h2_mttr) : 1e-4
              for c in String.(internal_links.carrier)]
line_lambda = repeat(reshape(lambda_vec, :, 1), 1, N_HOURS)
line_mu     = repeat(reshape(mu_vec,    :, 1), 1, N_HOURS)

lines = PRAS.Lines{N_HOURS,1,Hour,MW}(
    line_names, line_categories, line_forward, line_backward, line_lambda, line_mu,
)

interface_key = collect(zip(canon_from, canon_to))
perm = sortperm(interface_key)
sorted_keys = interface_key[perm]
unique_keys = unique(sorted_keys)

interface_line_idxs = Vector{UnitRange{Int}}(undef, length(unique_keys))
let pos = 1
    for (i, key) in enumerate(unique_keys)
        n = count(==(key), sorted_keys)
        interface_line_idxs[i] = pos:(pos + n - 1)
        pos += n
    end
end

lines = PRAS.Lines{N_HOURS,1,Hour,MW}(
    line_names[perm], line_categories[perm],
    line_forward[perm, :], line_backward[perm, :],
    line_lambda[perm, :], line_mu[perm, :],
)

regions_from = [k[1] for k in unique_keys]
regions_to   = [k[2] for k in unique_keys]
interface_forward  = Matrix{Int}(undef, length(unique_keys), N_HOURS)
interface_backward = Matrix{Int}(undef, length(unique_keys), N_HOURS)
for (i, rng) in enumerate(interface_line_idxs)
    interface_forward[i, :]  .= sum(line_forward_vec[perm][rng])
    interface_backward[i, :] .= sum(line_backward_vec[perm][rng])
end

interfaces = PRAS.Interfaces{N_HOURS,MW}(regions_from, regions_to, interface_forward, interface_backward)

println("  $(length(lines)) lines grouped into $(length(interfaces)) interfaces")

# -----------------------------------------------------------------------------
# 7. TIMESTAMPS
# -----------------------------------------------------------------------------
start_ts = ZonedDateTime(WEATHER_YEAR, 1, 1, 0, 0, 0, tz"UTC")
timestamps = start_ts : Hour(1) : (start_ts + Hour(N_HOURS - 1))
@assert length(timestamps) == N_HOURS "timestamps length $(length(timestamps)) != N_HOURS $N_HOURS"

# -----------------------------------------------------------------------------
# 8. ASSEMBLE + RUN
# -----------------------------------------------------------------------------
println("=== Assembling SystemModel ===")

sys = PRAS.SystemModel(
    regions, interfaces,
    gens, region_gen_idxs,
    storages, region_stor_idxs,
    generatorstorages, region_genstor_idxs,
    demandresponses, region_dr_idxs,
    lines, interface_line_idxs,
    timestamps,
)

println("  SystemModel built: $(length(regions)) regions, $(length(gens)) generators, ",
        "$(length(storages)) storages, $(length(lines)) lines")

println("=== Running reliability assessment ===")
shortfall, flow_res, util_res, gen_avail, stor_energy = PRAS.assess(
    sys,
    SequentialMonteCarlo(samples=100),
    Shortfall(), Flow(), Utilization(), GeneratorAvailability(), StorageEnergy()
)
 
println("Total system EUE = ", EUE(shortfall))
println("Total system NEUE = ", NEUE(shortfall))
println("Total system LOLE = ", LOLE(shortfall))

# -----------------------------------------------------------------------------
# 9. SAVE for reuse
# -----------------------------------------------------------------------------
serialize(joinpath(ROOT, "pras_system.jls"), sys)
serialize(joinpath(ROOT, "pras_results.jls"), shortfall)
serialize(joinpath(ROOT, "pras_flow.jls"),         flow_res)
serialize(joinpath(ROOT, "pras_utilization.jls"),  util_res)
serialize(joinpath(ROOT, "pras_gen_availability.jls"), gen_avail)
serialize(joinpath(ROOT, "pras_stor_energy.jls"),      stor_energy)
println("Saved system to ", joinpath(ROOT, "pras_system.jls"))
println("Saved results to ", joinpath(ROOT, "pras_results.jls"))