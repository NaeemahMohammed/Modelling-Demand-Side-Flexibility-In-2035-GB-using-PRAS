#!/usr/bin/env julia
# =============================================================================
# extract_results.jl (2035 version)
#
# N_HOURS = 8760 and WEATHER_YEAR = 2020, matching the 2035 build script.
# Timestamps are built FROM N_HOURS and WEATHER_YEAR directly (start date +
# N_HOURS-1 hours) rather than a hardcoded year-end literal -- the original
# 2024 version of this script had "ZonedDateTime(2024,12,31,23,...)" baked
# in, which produces 8784 hours regardless of what N_HOURS says (2024 is a
# leap year), so the two could silently disagree. This can't happen here.
# =============================================================================

using PRAS
using Serialization
using CSV
using DataFrames
using TimeZones
using Dates

const ROOT = @__DIR__
datapath(f) = joinpath(ROOT, "data", f)
# Read directly from run_metadata.txt -- written by the build script for
# THIS exact run, so it's physically impossible for these two scripts to
# disagree with each other again.
metadata = readlines(joinpath(ROOT, "run_metadata.txt"))
const N_HOURS = parse(Int, metadata[1])
const WEATHER_YEAR = parse(Int, metadata[2])
println("  Read from run_metadata.txt: N_HOURS = $N_HOURS, WEATHER_YEAR = $WEATHER_YEAR")

println("=== Loading saved results ===")
println("  pras_results.jls size: ", round(filesize(joinpath(ROOT, "pras_results.jls"))/1e6, digits=1), " MB")
shortfall = deserialize(joinpath(ROOT, "pras_results.jls"))

# Save correct PRAS headline metrics for MATLAB
metrics_df = DataFrame(
    eue_mwh  = [round(val(EUE(shortfall)),  digits=1)],
    lole_h   = [round(val(LOLE(shortfall)), digits=2)],
    neue_ppm = [round(val(NEUE(shortfall)), digits=1)],
    eue_std  = [round(stderror(EUE(shortfall)),  digits=1)],
    lole_std = [round(stderror(LOLE(shortfall)), digits=2)],
    neue_std = [round(stderror(NEUE(shortfall)), digits=1)],
)
CSV.write(joinpath(ROOT, "pras_headline_metrics.csv"), metrics_df)
println("→ Saved pras_headline_metrics.csv (EUE=", metrics_df.eue_mwh[1], " MWh, LOLE=", metrics_df.lole_h[1], " h/yr)")

buses_df = CSV.read(datapath("buses.csv"), DataFrame)
region_names_raw = String.(filter(row -> startswith(strip(row.name), "Z"), buses_df).name)

function zone_sort_key(name::AbstractString)
    m = match(r"^Z(\d+)(?:_(\d+))?$", name)
    m === nothing && return (typemax(Int), typemax(Int), name)
    major = parse(Int, m.captures[1])
    minor = m.captures[2] === nothing ? 0 : parse(Int, m.captures[2])
    return (major, minor, "")
end
region_names = sort(region_names_raw, by=zone_sort_key)
n_regions = length(region_names)

start_ts = ZonedDateTime(WEATHER_YEAR, 1, 1, 0, 0, 0, tz"UTC")
timestamps = start_ts : Hour(1) : (start_ts + Hour(N_HOURS - 1))
n_hours = length(timestamps)
@assert n_hours == N_HOURS "timestamps length $n_hours != N_HOURS $N_HOURS"

println("  $n_regions regions, $n_hours hours")
println("  Region order (sorted for export): ", join(region_names, ", "))

open(joinpath(ROOT, "region_names.txt"), "w") do io
    println(io, "regions = {", join("'" .* region_names .* "'", ","), "};")
end
println("  Wrote region_names.txt -- paste that line into your MATLAB script")

println("=== Building shortfall_mean matrix ($n_regions x $n_hours) ===")
shortfall_mean = Matrix{Float64}(undef, n_regions, n_hours)
for (r, region) in enumerate(region_names)
    for (t, ts) in enumerate(timestamps)
        m, _ = shortfall[region, ts]
        shortfall_mean[r, t] = m
    end
    println("  ...region $r/$n_regions ($region) done")
end
CSV.write(joinpath(ROOT, "shortfall_mean.csv"), DataFrame(shortfall_mean, :auto); writeheader=false)
println("  Wrote shortfall_mean.csv")

println("=== Building eventperiod_regionperiod_mean matrix ($n_regions x $n_hours) ===")
eventperiod_regionperiod_mean = Matrix{Float64}(undef, n_regions, n_hours)
for (r, region) in enumerate(region_names)
    for (t, ts) in enumerate(timestamps)
        eventperiod_regionperiod_mean[r, t] = val(LOLE(shortfall, region, ts))
    end
    println("  ...region $r/$n_regions ($region) done")
end
CSV.write(joinpath(ROOT, "eventperiod_regionperiod_mean.csv"), DataFrame(eventperiod_regionperiod_mean, :auto); writeheader=false)
println("  Wrote eventperiod_regionperiod_mean.csv")

println("\nDone.")