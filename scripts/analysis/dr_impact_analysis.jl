#!/usr/bin/env julia
# =============================================================================
# dr_impact_analysis.jl
#
# Answers Elina's questions after seeing DR results:
#   1. Why do some regions have HIGHER EUE/LOLE after DR?
#   2. Average SOC for batteries and H2 — compare DR vs no-DR
#   3. How much energy from batteries is actually being used?
#   4. Time-of-day breakdown of storage and DR utilisation
#   5. How much DR is used in different regions?
#   6. PRAS dispatch logic explanation
#
# Requires: run reload_session.jl first, then set NO_DR_ROOT below.
# Exports: dr_impact_*.csv files for MATLAB
# =============================================================================

using CSV, DataFrames, Statistics, Serialization

println("\n" * "="^70)
println("DR IMPACT ANALYSIS — POST-DR DIAGNOSTICS")
println("="^70)

# ── Path to the matching no-DR scenario ────────────────────────────────────────
# Change this to match whichever pair you're comparing
NO_DR_ROOT = replace(ROOT, "DR" => "")   # e.g. GBReliability2035DR → GBReliability2035
println("DR scenario:    $ROOT")
println("No-DR scenario: $NO_DR_ROOT")
println()

# ── Load shortfall matrices for both scenarios ─────────────────────────────────
sf_dr    = Matrix{Float64}(CSV.read(joinpath(ROOT,       "shortfall_mean.csv"), DataFrame; header=false))
sf_nodr  = Matrix{Float64}(CSV.read(joinpath(NO_DR_ROOT, "shortfall_mean.csv"), DataFrame; header=false))

sys_sf_dr   = vec(sum(sf_dr,   dims=1))
sys_sf_nodr = vec(sum(sf_nodr, dims=1))

total_eue_dr   = sum(sys_sf_dr)
total_eue_nodr = sum(sys_sf_nodr)

println("System-level results:")
println("  No-DR EUE: $(round(total_eue_nodr/1000, digits=1)) GWh")
println("  DR EUE:    $(round(total_eue_dr/1000,   digits=1)) GWh")
println("  Change:    $(round((total_eue_dr-total_eue_nodr)/1000, digits=1)) GWh  ",
        total_eue_dr > total_eue_nodr ? "(WORSE ↑)" : "(BETTER ↓)")

# ── 1. REGIONAL EUE CHANGE ─────────────────────────────────────────────────────
println("\n--- 1. REGIONAL EUE CHANGE AFTER DR ---")
println(rpad("Zone",10), rpad("No-DR EUE (MWh)",18), rpad("DR EUE (MWh)",15),
        rpad("Change (MWh)",14), "Direction")

regional_rows = []
gb_zones = sort(filter(r->startswith(r,"Z"), region_names), by=zone_sort_key)
for (ri, region) in enumerate(region_names)
    ri > size(sf_dr,1) && break
    eue_nodr = sum(sf_nodr[ri,:])
    eue_dr   = sum(sf_dr[ri,:])
    delta    = eue_dr - eue_nodr
    abs(eue_nodr) < 0.1 && abs(eue_dr) < 0.1 && continue
    direction = delta > 1 ? "⬆ WORSE" : delta < -1 ? "⬇ better" : "≈ unchanged"
    println(rpad(region,10), rpad(round(eue_nodr,digits=1),18),
            rpad(round(eue_dr,digits=1),15), rpad(round(delta,digits=1),14), direction)
    push!(regional_rows, (zone=region, eue_nodr=round(eue_nodr,digits=1),
                           eue_dr=round(eue_dr,digits=1), delta=round(delta,digits=1),
                           pct_change=round(100*delta/max(eue_nodr,1),digits=2)))
end
CSV.write(joinpath(ROOT,"dr_regional_impact.csv"), DataFrame(regional_rows))
println("  → Saved dr_regional_impact.csv")

# ── 2. WHY DOES DR WORSEN SOME REGIONS? ───────────────────────────────────────
println("\n--- 2. WHY DR WORSENS SOME REGIONS ---")
println("DR (shift) borrows load from stressed hours and repays within 4h.")
println("If the stress event lasts > 4h, repayment lands in another stressed hour.")
println()
println("Event duration analysis for DR vs no-DR:")

# Count shortfall events per scenario
function detect_events_simple(sys_sf)
    events = []
    in_event = false; start_t = 0; dur = 0
    for t in 1:length(sys_sf)
        if sys_sf[t] > 0.1
            if !in_event; in_event=true; start_t=t; dur=1
            else; dur+=1; end
        else
            if in_event
                push!(events, (start=start_t, duration=dur))
                in_event=false; dur=0
            end
        end
    end
    return events
end

ev_nodr = detect_events_simple(sys_sf_nodr)
ev_dr   = detect_events_simple(sys_sf_dr)

println("  No-DR: $(length(ev_nodr)) events, mean duration $(round(mean([e.duration for e in ev_nodr]),digits=1)) hrs")
println("  DR:    $(length(ev_dr))   events, mean duration $(round(mean([e.duration for e in ev_dr]),digits=1)) hrs")
println("  → Events that are LONGER after DR = payback creating new shortfall hours")

short_events_nodr = count(e -> e.duration <= 4, ev_nodr)
long_events_nodr  = count(e -> e.duration >  4, ev_nodr)
println("\n  No-DR events ≤4h (DR payback window):  $short_events_nodr  ← DR COULD help these")
println("  No-DR events >4h (beyond payback):     $long_events_nodr  ← DR CANNOT help, may worsen")

# ── 3. STORAGE SOC COMPARISON ─────────────────────────────────────────────────
println("\n--- 3. STORAGE STATE OF CHARGE: DR vs NO-DR ---")

stor_dr_path   = joinpath(ROOT,       "pras_stor_energy.jls")
stor_nodr_path = joinpath(NO_DR_ROOT, "pras_stor_energy.jls")

if isfile(stor_dr_path) && isfile(stor_nodr_path) && @isdefined(stor_energy)
    stor_dr   = stor_energy   # already loaded
    stor_nodr = deserialize(stor_nodr_path)

    H2_NAME = "GB_H2_storage"
    H2_CAP  = 658_421.064

    h2_soc_dr   = [stor_dr[H2_NAME,   ts][1] for ts in timestamps]
    h2_soc_nodr = [stor_nodr[H2_NAME, ts][1] for ts in timestamps]

    println("\n  H2 Storage SOC:")
    println("    No-DR mean SOC: $(round(mean(h2_soc_nodr)/H2_CAP*100,digits=1))% full")
    println("    DR mean SOC:    $(round(mean(h2_soc_dr)/H2_CAP*100,digits=1))% full")
    println("    → ", mean(h2_soc_dr) > mean(h2_soc_nodr) ?
            "DR leaves H2 FULLER — less discharging during DR payback hours?" :
            "DR leaves H2 EMPTIER — DR payback hours are charging the store")

    # H2 SOC by hour of day
    hod_soc_dr   = zeros(24); hod_soc_nodr = zeros(24); hod_count = zeros(24)
    for (t, ts) in enumerate(timestamps)
        h = mod(t-1, 24) + 1
        hod_soc_dr[h]   += h2_soc_dr[t] / H2_CAP * 100
        hod_soc_nodr[h] += h2_soc_nodr[t] / H2_CAP * 100
        hod_count[h] += 1
    end
    hod_soc_dr   ./= hod_count
    hod_soc_nodr ./= hod_count

    hod_df = DataFrame(hour_of_day=0:23,
                        h2_soc_nodr_pct=round.(hod_soc_nodr, digits=2),
                        h2_soc_dr_pct  =round.(hod_soc_dr,   digits=2),
                        difference     =round.(hod_soc_dr .- hod_soc_nodr, digits=2))
    CSV.write(joinpath(ROOT,"dr_h2_soc_by_hour.csv"), hod_df)
    println("  → Saved dr_h2_soc_by_hour.csv")

    # Battery SOC comparison
    println("\n  Battery SOC during shortfall hours:")
    sf_hrs = findall(sys_sf_dr .> 0.1)
    batt_rows = []
    stor_df = CSV.read(datapath("storage_static.csv"), DataFrame)
    stor_df.bus = strip.(String.(stor_df.bus))
    stor_df = filter(row -> row.bus in Set(region_names), stor_df)
    for zone in sorted_regs
        zs = filter(row -> row.bus == zone, stor_df)
        isempty(zs) && continue
        ri = findfirst(==(zone), region_names)
        isnothing(ri) && continue
        zone_sf = findall(sf_dr[ri,:] .> 0.1)
        isempty(zone_sf) && continue
        tot_mwh = sum(zs.p_nom .* zs.max_hours)
        tot_mwh < 1 && continue
        soc_vals_dr = Float64[]; soc_vals_nodr = Float64[]
        for row in eachrow(zs)
            cap = row.p_nom * row.max_hours
            cap < 0.1 && continue
            for t in zone_sf
                try
                    push!(soc_vals_dr,   100*stor_dr[String(row.name),   timestamps[t]][1]/cap)
                    push!(soc_vals_nodr, 100*stor_nodr[String(row.name), timestamps[t]][1]/cap)
                catch; end
            end
        end
        isempty(soc_vals_dr) && continue
        push!(batt_rows, (zone=zone, mean_soc_nodr=round(mean(soc_vals_nodr),digits=1),
                           mean_soc_dr=round(mean(soc_vals_dr),digits=1),
                           total_mwh=round(Int,tot_mwh)))
        println("  $(rpad(zone,8)) battery SOC at UE:  no-DR=$(round(mean(soc_vals_nodr),digits=1))%  DR=$(round(mean(soc_vals_dr),digits=1))%  ($(round(Int,tot_mwh)) MWh)")
    end
    CSV.write(joinpath(ROOT,"dr_battery_soc_comparison.csv"), DataFrame(batt_rows))
    println("  → Saved dr_battery_soc_comparison.csv")
else
    println("  pras_stor_energy.jls not found for one or both scenarios")
    println("  Run both builds with StorageEnergy() in assess() call")
end

# ── 4. SHORTFALL TIME-OF-DAY COMPARISON ────────────────────────────────────────
println("\n--- 4. SHORTFALL BY TIME OF DAY: DR vs NO-DR ---")

hod_sf_dr   = zeros(24); hod_sf_nodr = zeros(24); hod_cnt = zeros(Int,24)
for t in 1:N_HOURS
    h = mod(t-1,24) + 1
    hod_sf_dr[h]   += sys_sf_dr[t]
    hod_sf_nodr[h] += sys_sf_nodr[t]
    hod_cnt[h] += 1
end

tod_df = DataFrame(
    hour_of_day  = 0:23,
    eue_nodr_mwh = round.(hod_sf_nodr, digits=1),
    eue_dr_mwh   = round.(hod_sf_dr,   digits=1),
    delta_mwh    = round.(hod_sf_dr .- hod_sf_nodr, digits=1),
    pct_change   = round.(100*(hod_sf_dr .- hod_sf_nodr) ./ max.(hod_sf_nodr, 1), digits=2)
)
CSV.write(joinpath(ROOT,"dr_shortfall_by_hour.csv"), tod_df)
println("  Peak shortfall hour (no-DR): ", argmax(hod_sf_nodr)-1, ":00")
println("  Peak shortfall hour (DR):    ", argmax(hod_sf_dr)-1, ":00")
println("  Worst hour for DR payback (biggest increase): ",
        argmax(hod_sf_dr .- hod_sf_nodr)-1, ":00 (+",
        round(maximum(hod_sf_dr .- hod_sf_nodr),digits=0), " MWh)")
println("  → Saved dr_shortfall_by_hour.csv")

# ── 5. PRAS DISPATCH LOGIC EXPLANATION ────────────────────────────────────────
println("\n--- 5. PRAS DISPATCH LOGIC (how DR interacts with storage) ---")
println("""
PRAS uses a GREEDY SEQUENTIAL DISPATCH at each timestep:
  1. Generators dispatch to cover local demand
  2. DR units borrow load first (reduces effective demand in that hour)
  3. Storage discharges to cover remaining deficit
  4. Surplus flows via Lines to neighbouring deficit regions
  5. Any remaining deficit = shortfall (unserved energy)

In a LATER hour (within DR_PAYBACK_HRS):
  1. DR payback demand is ADDED to load (increases effective demand)
  2. If generators + storage can cover this increased demand → no problem
  3. If generators + storage CANNOT cover → shortfall INCREASES due to DR

Key insight: PRAS dispatches DR payback BEFORE storage charging.
  → Surplus generation in payback hours goes to DR payback first, not H2 storage
  → This can reduce H2 charging in the hours following a DR event
  → Less H2 energy available for subsequent stress periods

This explains why DR can increase EUE in some regions:
  - DR removes load from hour T (helps)
  - Payback at hour T+k adds load to an already stressed hour (hurts)
  - The hurt outweighs the help for multi-hour events
""")

# ── 6. BATTERY CHARGING/DISCHARGING BY TIME OF DAY ────────────────────────────
println("\n--- 6. BATTERY CHARGING/DISCHARGING BY TIME OF DAY ---")

if isfile(stor_dr_path) && isfile(stor_nodr_path) && @isdefined(stor_energy)
  let
    stor_dr   = stor_energy
    stor_nodr = deserialize(stor_nodr_path)
    stor_df   = CSV.read(datapath("storage_static.csv"), DataFrame)
    stor_df.bus = strip.(String.(stor_df.bus))
    stor_df = filter(row -> row.bus in Set(region_names), stor_df)
    batt_df = filter(row -> !occursin("H2",String(row.name)), stor_df)

    all_soc_dr   = zeros(Float64, N_HOURS)
    all_soc_nodr = zeros(Float64, N_HOURS)
    total_capacity = 0.0

    for row in eachrow(batt_df)
        cap = row.p_nom * row.max_hours
        cap < 0.1 && continue
        total_capacity += cap
        for (t, ts) in enumerate(timestamps)
            try
                all_soc_dr[t]   += stor_dr[String(row.name),   ts][1]
                all_soc_nodr[t] += stor_nodr[String(row.name), ts][1]
            catch; end
        end
    end

    # Compute charge/discharge per hour (delta SOC)
    delta_dr   = diff(all_soc_dr)    # positive=charging, negative=discharging
    delta_nodr = diff(all_soc_nodr)

    # Group by hour of day
    hod_charge_dr   = zeros(24); hod_discharge_dr   = zeros(24)
    hod_charge_nodr = zeros(24); hod_discharge_nodr = zeros(24)
    hod_n = zeros(Int,24)

    for t in 1:length(delta_dr)
        h = mod(t-1,24) + 1
        hod_n[h] += 1
        delta_dr[t]   > 0 ? hod_charge_dr[h]   += delta_dr[t]   : hod_discharge_dr[h]   += abs(delta_dr[t])
        delta_nodr[t] > 0 ? hod_charge_nodr[h] += delta_nodr[t] : hod_discharge_nodr[h] += abs(delta_nodr[t])
    end
    hod_charge_dr   ./= hod_n; hod_discharge_dr   ./= hod_n
    hod_charge_nodr ./= hod_n; hod_discharge_nodr ./= hod_n

    # Total annual energy from batteries
    total_discharge_dr   = sum(abs.(min.(0.0, delta_dr)))
    total_discharge_nodr = sum(abs.(min.(0.0, delta_nodr)))
    total_charge_dr      = sum(max.(0.0, delta_dr))
    total_charge_nodr    = sum(max.(0.0, delta_nodr))

    println("  Total battery capacity: $(round(total_capacity/1000,digits=1)) GWh")
    println("\n  Annual energy delivered by batteries:")
    println("    No-DR: $(round(total_discharge_nodr/1000,digits=1)) GWh discharged")
    println("    DR:    $(round(total_discharge_dr/1000,  digits=1)) GWh discharged")
    println("    Change: $(round((total_discharge_dr-total_discharge_nodr)/1000,digits=2)) GWh")
    println("\n  Annual energy stored in batteries:")
    println("    No-DR: $(round(total_charge_nodr/1000,digits=1)) GWh charged")
    println("    DR:    $(round(total_charge_dr/1000,  digits=1)) GWh charged")

    battery_hod = DataFrame(
        hour_of_day           = 0:23,
        charge_nodr_mwh       = round.(hod_charge_nodr,   digits=2),
        discharge_nodr_mwh    = round.(hod_discharge_nodr, digits=2),
        charge_dr_mwh         = round.(hod_charge_dr,     digits=2),
        discharge_dr_mwh      = round.(hod_discharge_dr,   digits=2),
        net_nodr_mwh          = round.(hod_charge_nodr .- hod_discharge_nodr, digits=2),
        net_dr_mwh            = round.(hod_charge_dr   .- hod_discharge_dr,   digits=2),
    )
    CSV.write(joinpath(ROOT,"dr_battery_charging_hod.csv"), battery_hod)

    battery_totals = DataFrame(
        metric = ["Total discharged (GWh)","Total charged (GWh)",
                   "Net (GWh)","Capacity utilization (%)"],
        no_dr  = [round(total_discharge_nodr/1000,digits=1), round(total_charge_nodr/1000,digits=1),
                   round((total_discharge_nodr-total_charge_nodr)/1000,digits=1),
                   round(100*total_discharge_nodr/(total_capacity*N_HOURS),digits=2)],
        with_dr= [round(total_discharge_dr/1000,  digits=1), round(total_charge_dr/1000,  digits=1),
                   round((total_discharge_dr-total_charge_dr)/1000,digits=1),
                   round(100*total_discharge_dr/(total_capacity*N_HOURS),digits=2)],
    )
    CSV.write(joinpath(ROOT,"dr_battery_energy_totals.csv"), battery_totals)
    println("  → Saved dr_battery_charging_hod.csv")
    println("  → Saved dr_battery_energy_totals.csv")
  end # let
else
    println("  pras_stor_energy.jls missing — run build with StorageEnergy()")
end

# ── 7. DR UTILIZATION BY ZONE ──────────────────────────────────────────────────
println("\n--- 7. DR UTILIZATION BY ZONE ---")
println("Proxy: shortfall reduction per zone / DR capacity in that zone")
println("Zones with high utilization = DR was effective there")
println("Zones with low (or negative) utilization = DR created payback problems")
println()

dr_params_path = joinpath(ROOT,"dr_parameters_used.csv")
if isfile(dr_params_path)
    dr_params = CSV.read(dr_params_path, DataFrame)
    util_rows = []
    for row in eachrow(dr_params)
        ri = findfirst(==(row.zone), region_names)
        ri === nothing && continue
        ri > size(sf_dr,1) && continue
        eue_nodr = sum(sf_nodr[ri,:])
        eue_dr   = sum(sf_dr[ri,:])
        delta = eue_nodr - eue_dr   # positive = DR helped this zone
        dr_capacity_mwh = row.max_buffer_mwh   # maximum energy DR can shift

        # Utilization proxy: how much of DR's theoretical benefit was realised?
        # Theoretical max benefit = DR_capacity × fraction of stressed hours
        n_stressed = count(>(0.1), sf_nodr[ri,:])
        theoretical_max = row.borrow_mw * n_stressed  # if DR ran every stressed hour
        util_pct = theoretical_max > 0 ? 100*delta/theoretical_max : 0.0

        status = if delta > 100;      "✓ helped significantly"
                 elseif delta > 0;    "≈ marginal benefit"
                 elseif eue_nodr < 1; "— zone had no shortfall (payback risk)"
                 else;                "✗ DR made it worse"
                 end

        println("  $(rpad(row.zone,8)) DR=$(row.borrow_mw)MW  ",
                "EUE: $(round(eue_nodr,digits=0))→$(round(eue_dr,digits=0)) MWh  ",
                "Δ=$(round(delta,digits=0)) MWh  $status")

        push!(util_rows,(
            zone=row.zone, dr_borrow_mw=row.borrow_mw,
            dr_buffer_mwh=row.max_buffer_mwh,
            eue_nodr_mwh=round(eue_nodr,digits=1),
            eue_dr_mwh=round(eue_dr,digits=1),
            eue_change_mwh=round(delta,digits=1),
            status=status,
        ))
    end
    CSV.write(joinpath(ROOT,"dr_utilization_by_zone.csv"), DataFrame(util_rows))
    println("  → Saved dr_utilization_by_zone.csv")

    # Summary: highest and lowest DR utilization zones
    util_df = DataFrame(util_rows)
    helped   = filter(row->row.eue_change_mwh > 100, util_df)
    worsened = filter(row->row.eue_change_mwh < -100, util_df)
    neutral  = filter(row->abs(row.eue_change_mwh) <= 100, util_df)
    println("\n  Summary:")
    println("  Zones where DR helped:    $(nrow(helped)) ($(join(helped.zone, ", ")))")
    println("  Zones where DR worsened:  $(nrow(worsened)) ($(join(worsened.zone, ", ")))")
    println("  Zones with no effect:     $(nrow(neutral)) ($(join(neutral.zone, ", ")))")
else
    println("  dr_parameters_used.csv not found — run build script first")
end

println("\n" * "="^70)
println("DONE — CSVs ready for MATLAB")
println("="^70)