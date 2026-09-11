#!/usr/bin/env julia
# =============================================================================
# build_gb_pras_system.jl
#
# One-file version of the GB reliability PRAS build, reconstructed from your
# interactive REPL session. This is what your session ACTUALLY ended up doing
# (not the capacity_by_region.csv design from earlier in our chat -- you went
# a different, equally valid route, using the individual-generator register
# in generators_static.csv directly). Running this top to bottom should
# reproduce the SystemModel + assess() run you got working.
#
# Three things I changed vs. your literal session, flagged so nothing is
# silently different:
#
#   1. FIXED A BUG: your session computed
#         lambda = gen_df.FOR ./ gen_df.MTTF_hours
#      partway through. FOR (= MTTR/(MTTF+MTTR)) is a *fraction*, so dividing
#      it by MTTF_hours again produces a failure rate with the wrong units/
#      magnitude. The standard, and what your LAST successful run actually
#      used, is simply lambda = 1/MTTF_hours, mu = 1/MTTR_hours. This script
#      uses that throughout. FOR is still computed and saved as a reference
#      column in pras_generators.csv, just not fed into lambda directly.
#
#   2. TIMESTAMPS: your session set these to year 2024 in most places but to
#      2020 in one spot late in the session (and nothing reset it back
#      afterwards). Your data is 2024 (loads_p_set.csv, renewables files), so
#      this script uses 2024 -- using 2020 would just mislabel the x-axis on
#      any time series you plot, it doesn't affect the reliability numbers
#      themselves.
#
#   3. WEATHER DATA IS WIRED IN, TWO LAYERS: wind/solar generators first try
#      to match a named column in generators_p_max_pu.csv (per-farm hourly
#      capacity factor). Anything that doesn't match falls back to
#      renewables_cf_by_region.csv (one curve per region+carrier) -- this
#      catches small_hydro/tidal_stream/shoreline_wave and any wind/solar
#      unit not individually named in the per-farm file. Whatever's left
#      after both (thermal, large_hydro, etc.) stays at flat nameplate.
#
# Also: interconnectors are excluded. Your session explicitly filtered
# `regions` down to GB zones only (names starting with "Z") and dropped
# EU_import generators, so the 4 HVDC_External_* buses and their 6
# interconnector links aren't part of this system at all. That's a real
# modelling choice, not an oversight on my part -- flagging it so it doesn't
# surprise you later. Re-adding them is a moderate amount of extra work
# (they'd need their own region + load + a line that doesn't just connect two
# GB zones), so just ask if/when you want that.
#
# REQUIRED PACKAGES (install once if you haven't already):
#   using Pkg
#   Pkg.add(["CSV", "DataFrames", "Dates", "TimeZones", "Serialization", "Statistics"])
#   (PRAS itself -- you already have this installed and working)
# =============================================================================

using CSV
using DataFrames
using Dates
using TimeZones
using PRAS
using Serialization
using Statistics

# -----------------------------------------------------------------------------
# 0. PROJECT ROOT -- edit this one line if you run the script from somewhere
#    other than inside GBReliability/. Defaults to "wherever this file is".
# -----------------------------------------------------------------------------
const ROOT = @__DIR__
datapath(f) = joinpath(ROOT, "data", f)

const N_HOURS = 8784   # 2024 is a leap year -- 366 * 24

println("=== Loading raw data ===")

buses_df       = CSV.read(datapath("buses.csv"), DataFrame)
links_df       = CSV.read(datapath("links.csv"), DataFrame)
gen_static_df  = CSV.read(datapath("generators_static.csv"), DataFrame)
reliability_df = CSV.read(datapath("generator_reliability.csv"), DataFrame)
storage_df     = CSV.read(datapath("storage_static.csv"), DataFrame)
loads_pset_df  = CSV.read(datapath("loads_p_set.csv"), DataFrame)


# -----------------------------------------------------------------------------
# 1. GENERATORS -- join the individual-generator register against carrier-
#    level reliability stats, drop interconnector-only generators, save a
#    pras_generators.csv checkpoint (handy for inspecting in Excel later).
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

# Generators sitting at the 4 HVDC_External_* buses (however your carrier
# column happens to label them) get dropped in Step 3 below, once we know
# which bus names are valid GB regions. Doing it there instead of guessing
# a carrier name here means it can't miss anything.

CSV.write(datapath("pras_generators.csv"), pras_generators)
println("  Wrote ", datapath("pras_generators.csv"), " (", nrow(pras_generators), " generators, before region filtering)")

# -----------------------------------------------------------------------------
# 2. REGIONS -- GB zones only (bus names starting with "Z"), real hourly load.
# -----------------------------------------------------------------------------
println("=== Building regions ===")

gb_buses = filter(row -> startswith(strip(row.name), "Z"), buses_df)
region_names = strip.(String.(gb_buses.name))             # e.g. "Z10", "Z1_1", ...
n_regions = length(region_names)

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

regions = PRAS.Regions{N_HOURS, MW}(region_names, load_matrix)
region_index = Dict(name => i for (i, name) in enumerate(region_names))

println("  $n_regions regions, peak combined load = ", maximum(vec(sum(load_matrix, dims=1))), " MW")

# -----------------------------------------------------------------------------
# 3. GENERATORS -> PRAS.Generators, grouped contiguously by region.
# -----------------------------------------------------------------------------
println("=== Building PRAS generators ===")

# Drop ANY generator whose bus isn't one of our 20 GB regions -- this is the
# real interconnector-exclusion step (replaces the carrier-name guess from
# Step 1). Comparison is whitespace-trimmed in case of stray spaces in
# either CSV.
gen_bus_clean = strip.(String.(pras_generators.bus))
region_set = Set(region_names)
n_before = nrow(pras_generators)
keep = [b in region_set for b in gen_bus_clean]
dropped_buses = unique(gen_bus_clean[.!keep])
pras_generators = pras_generators[keep, :]
pras_generators.bus = gen_bus_clean[keep]   # use the cleaned values from here on
println("  Dropped $(n_before - nrow(pras_generators)) generator(s) outside the $n_regions GB regions: ", dropped_buses)

# Sort generators so each region's are contiguous (PRAS requires this for
# the region_gen_idxs ranges to make sense).

# "load_shedding" is a placeholder for voluntary demand curtailment, not a
# real generator -- including it as 57.8 GW of always-available supply
# would let it silently cover any shortfall, masking the EUE/LOLE you're
# trying to measure. Drop it.
ls_capacity = sum(pras_generators.p_nom[pras_generators.carrier .== "load_shedding"])
n_before_ls = nrow(pras_generators)
pras_generators = filter(row -> row.carrier != "load_shedding", pras_generators)
println("  Dropped $(n_before_ls - nrow(pras_generators)) load_shedding generator(s) totalling ",
        round(ls_capacity, digits=1), " MW (not a real supply resource)")
		
sort_perm = sortperm(pras_generators.bus, by = b -> region_index[b])
pras_generators = pras_generators[sort_perm, :]

gen_names      = Vector{String}(pras_generators.name)
gen_categories = Vector{String}(pras_generators.carrier)
gen_capacity   = repeat(reshape(round.(Int, pras_generators.p_nom), :, 1), 1, N_HOURS)
gen_lambda     = repeat(reshape(1.0 ./ Float64.(pras_generators.MTTF_hours), :, 1), 1, N_HOURS)
gen_mu         = repeat(reshape(1.0 ./ Float64.(pras_generators.MTTR_hours), :, 1), 1, N_HOURS)

# --- Weather-driven capacity for wind/solar -----------------------------
# generators_p_max_pu.csv has one column per named wind/solar farm giving
# its hourly capacity factor (0-1). Where a generator's name matches a
# column, swap its flat nameplate value above for p_nom * cf(t).
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

# --- Fallback: regional capacity factor for renewables with no per-farm
# match (e.g. small_hydro, tidal_stream, shoreline_wave, or any wind/solar
# unit generators_p_max_pu.csv doesn't happen to name individually).
# renewables_cf_by_region.csv gives one hourly profile per (bus, carrier) --
# every generator of that carrier in that region shares the same curve,
# which assumes their output moves together with regional weather. That's
# a reasonable approximation for things like co-located small hydro, but it
# does mean those units' outputs will be perfectly correlated with each
# other in the simulation, which a per-farm profile wouldn't impose.
renewables_cf_path = datapath("renewables_cf_by_region.csv")
if isfile(renewables_cf_path)
    cf_lines = readlines(renewables_cf_path)
    cf_bus_row     = split(cf_lines[1], ',')[2:end]
    cf_carrier_row = split(cf_lines[2], ',')[2:end]
    # cf_lines[3] is a label-only row ("snapshot", blank...) -- skip it
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

stor_names      = String.(storage_df.name)
stor_categories = String.(storage_df.carrier)
stor_charge_cap = repeat(reshape(round.(Int, storage_df.p_nom), :, 1), 1, N_HOURS)
stor_discharge_cap = copy(stor_charge_cap)
stor_energy_cap = repeat(reshape(round.(Int, storage_df.p_nom .* storage_df.max_hours), :, 1), 1, N_HOURS)
stor_charge_eff = repeat(reshape(Float64.(storage_df.efficiency_store), :, 1), 1, N_HOURS)
stor_discharge_eff = repeat(reshape(Float64.(storage_df.efficiency_dispatch), :, 1), 1, N_HOURS)
stor_carryover_eff = repeat(reshape(1.0 .- Float64.(storage_df.standing_loss), :, 1), 1, N_HOURS)

# No outage data exists for storage in your CSVs -- treated as effectively
# always available (failure once in ~114 years, repaired within the hour).
n_stor = nrow(storage_df)
stor_lambda = fill(1.0 / 1_000_000.0, n_stor, N_HOURS)
stor_mu     = fill(1.0, n_stor, N_HOURS)

storages = PRAS.Storages{N_HOURS,1,Hour,MW,MWh}(
    stor_names, stor_categories,
    stor_charge_cap, stor_discharge_cap, stor_energy_cap,
    stor_charge_eff, stor_discharge_eff, stor_carryover_eff,
    stor_lambda, stor_mu,
)

region_stor_idxs = Vector{UnitRange{Int}}(undef, n_regions)
let pos = 1
    for (i, region) in enumerate(region_names)
        n = count(==(region), storage_df.bus)
        region_stor_idxs[i] = n > 0 ? (pos:(pos + n - 1)) : (pos:(pos - 1))
        pos += n
    end
end

@assert sum(length, region_stor_idxs) == length(storages) "region_stor_idxs doesn't cover all storages"
println("  $(length(storages)) storage units across $n_regions regions")

# -----------------------------------------------------------------------------
# 5. No generator-storage or demand-response units in this system.
# -----------------------------------------------------------------------------
generatorstorages   = PRAS.GeneratorStorages{N_HOURS,1,Hour,MW,MWh}()
region_genstor_idxs = [1:0 for _ in 1:n_regions]
demandresponses     = PRAS.DemandResponses{N_HOURS,1,Hour,MW,MWh}()
region_dr_idxs      = [1:0 for _ in 1:n_regions]

# -----------------------------------------------------------------------------
# 6. LINES + INTERFACES -- GB-zone-to-GB-zone links only (interconnectors
#    excluded, see note at top of file).
# -----------------------------------------------------------------------------
println("=== Building lines and interfaces ===")

internal_links = filter(
    row -> !occursin("HVDC_External", row.bus0) && !occursin("HVDC_External", row.bus1),
    links_df,
)
n_dropped = nrow(links_df) - nrow(internal_links)
println("  Dropped $n_dropped interconnector link(s); $(nrow(internal_links)) internal lines remain")

link_bus0 = strip.(String.(internal_links.bus0))
link_bus1 = strip.(String.(internal_links.bus1))
bad_link_buses = unique(vcat(filter(b -> !haskey(region_index, b), link_bus0),
                              filter(b -> !haskey(region_index, b), link_bus1)))
isempty(bad_link_buses) || error("links.csv references bus(es) not in the GB region set: $bad_link_buses")

from_idx = [region_index[b] for b in link_bus0]
to_idx   = [region_index[b] for b in link_bus1]
# PRAS interfaces require regions_from[i] < regions_to[i]
canon_from = min.(from_idx, to_idx)
canon_to   = max.(from_idx, to_idx)

line_caps = round.(Int, internal_links.p_nom)
line_forward  = repeat(reshape(line_caps, :, 1), 1, N_HOURS)
line_backward = repeat(reshape(line_caps, :, 1), 1, N_HOURS)

line_names      = String.(internal_links.name)
line_categories = fill("Transmission", length(line_names))
# No outage data for transmission either -- same "effectively always
# available" convention as storage above. Override here if you get real
# circuit outage statistics.
line_lambda = fill(1e-6, length(line_names), N_HOURS)
line_mu     = fill(1e-4, length(line_names), N_HOURS)

lines = PRAS.Lines{N_HOURS,1,Hour,MW}(
    line_names, line_categories, line_forward, line_backward, line_lambda, line_mu,
)

# Group lines into interfaces (one interface per unique region pair)
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

# Reorder lines/lambda/mu to match the sorted-by-interface order
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
    interface_forward[i, :]  .= sum(line_caps[perm][rng])
    interface_backward[i, :] .= sum(line_caps[perm][rng])
end

interfaces = PRAS.Interfaces{N_HOURS,MW}(regions_from, regions_to, interface_forward, interface_backward)

println("  $(length(lines)) lines grouped into $(length(interfaces)) interfaces")

# -----------------------------------------------------------------------------
# 7. TIMESTAMPS
# -----------------------------------------------------------------------------
timestamps = ZonedDateTime(2024, 1, 1, 0, 0, 0, tz"UTC"):Hour(1):ZonedDateTime(2024, 12, 31, 23, 0, 0, tz"UTC")
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
shortfall, flow_res, util_res, gen_avail = PRAS.assess(
    sys,
    SequentialMonteCarlo(samples=1000, seed=42),
    Shortfall(), Flow(), Utilization(), GeneratorAvailability()
)

println("Total system EUE = ", EUE(shortfall))
println("Total system NEUE = ", NEUE(shortfall))
println("Total system LOLE = ", LOLE(shortfall))

# If LOLE errors in your PRAS version, run:
#   filter(x -> occursin("LOLE", uppercase(string(x))), names(PRAS))
# to find the exact exported name.

# -----------------------------------------------------------------------------
# 9. SAVE for reuse
# -----------------------------------------------------------------------------
serialize(joinpath(ROOT, "pras_system.jls"), sys)
serialize(joinpath(ROOT, "pras_results.jls"), shortfall)
serialize(joinpath(ROOT, "pras_flow.jls"),         flow_res)
serialize(joinpath(ROOT, "pras_utilization.jls"),  util_res)
serialize(joinpath(ROOT, "pras_gen_availability.jls"), gen_avail)
println("Saved system to ", joinpath(ROOT, "pras_system.jls"))
println("Saved results to ", joinpath(ROOT, "pras_results.jls"))

# To reload later without rerunning the whole build:
#   using PRAS, Serialization
#   sys = deserialize("pras_system.jls")
#   shortfall = deserialize("pras_results.jls")

# =============================================================================
# Part 1: Generator-to-region alignment audit
# =============================================================================
println("=== Alignment audit ===")

# If names and data ever desynced, this would be false. It can't be false
# unless something between the sort and here reordered one without the
# other -- this is the single strongest check available.
identity_check = gen_names == pras_generators.name
println("gen_names matches pras_generators.name row-for-row: ", identity_check)
identity_check || error("ALIGNMENT BUG CONFIRMED -- stop and send me this output")

# Confirms region_gen_idxs groups generators into the CORRECT region, not
# just into a region.
mismatch_found = false
for (i, region) in enumerate(region_names)
    rng = region_gen_idxs[i]
    if !isempty(rng)
        buses_in_range = unique(pras_generators.bus[rng])
        if buses_in_range != [region]
            println("  MISMATCH at $region (range $rng): contains bus(es) ", buses_in_range)
            mismatch_found = true
        end
    end
end
println(mismatch_found ? "  Mismatches found -- see above" : "  All regions check out -- every generator is grouped under its own bus, correctly.")