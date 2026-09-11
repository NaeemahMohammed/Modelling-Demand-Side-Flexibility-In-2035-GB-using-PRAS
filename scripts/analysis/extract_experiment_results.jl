# =============================================================================
# extract_experiment_results.jl
#
# Full extraction script — deserialises all saved .jls files, prints
# headline metrics, investigates structural deficit, transmission utilisation,
# H2 charging/discharging, battery SOC at shortfall, and saves everything
# to labelled CSVs.
#
# Usage:
#   1. Change LABEL and ROOT below to match your run
#   2. include(raw"...\extract_experiment_results.jl")
# =============================================================================

using PRAS, Serialization, Statistics, CSV, DataFrames, TimeZones

# ── SETTINGS — change these per run ──────────────────────────────────────────
ROOT  = raw"C:\Users\naeem\OneDrive - Imperial College London\Desktop\Individual Research Project\GBReliability2035_experiment"
LABEL = "10x_transmission_27434MW_H2"   # change per run to avoid overwriting

# ── 1. DESERIALISE ────────────────────────────────────────────────────────────
println("="^65)
println("LOADING SAVED RESULTS — $LABEL")
println("="^65)
sys             = deserialize(joinpath(ROOT, "pras_system.jls"))
shortfall_res   = deserialize(joinpath(ROOT, "pras_results.jls"))
stor_energy_res = deserialize(joinpath(ROOT, "pras_stor_energy.jls"))
flow_res        = deserialize(joinpath(ROOT, "pras_flow.jls"))
println("  All files loaded.")

N_HOURS    = length(sys.timestamps)
zone_names = String.(sys.regions.names)
start_ts   = ZonedDateTime(2035, 1, 1, 0, 0, 0, tz"UTC")

# ── 2. HEADLINE METRICS ───────────────────────────────────────────────────────
println()
println("="^65)
println("HEADLINE METRICS")
println("="^65)
eue_val  = val(EUE(shortfall_res));  eue_std  = stderror(EUE(shortfall_res))
lole_val = val(LOLE(shortfall_res)); lole_std = stderror(LOLE(shortfall_res))
neue_val = val(NEUE(shortfall_res)); neue_std = stderror(NEUE(shortfall_res))
println("  EUE:  $(round(eue_val,  digits=0)) ± $(round(eue_std,  digits=0)) MWh/yr")
println("  LOLE: $(round(lole_val, digits=2)) ± $(round(lole_std, digits=2)) h/yr")
println("  NEUE: $(round(neue_val, digits=0)) ± $(round(neue_std, digits=0)) ppm")

# ── 3. GENERATION vs DEMAND ───────────────────────────────────────────────────
println()
println("="^65)
println("GENERATION vs DEMAND (structural deficit)")
println("="^65)
sys_gen    = vec(sum(Float64.(sys.generators.capacity), dims=1))
sys_demand = vec(sum(Float64.(sys.regions.load),        dims=1))
deficit    = sys_demand .- sys_gen

total_demand_TWh = sum(Float64.(sys.regions.load))    / 1e6
total_gen_TWh    = sum(Float64.(sys.generators.capacity)) / 1e6
println("  Total annual demand:     $(round(total_demand_TWh, digits=1)) TWh")
println("  Total annual generation: $(round(total_gen_TWh,    digits=1)) TWh")
println("  Gen/demand ratio:        $(round(total_gen_TWh/total_demand_TWh, digits=2))×")
println("  Hours gen < demand:      $(sum(deficit .> 0)) / $N_HOURS")
println("  Max structural deficit:  $(round(maximum(deficit)/1000, digits=1)) GW")

println()
println("  Top 10 worst hours:")
println("  ", rpad("Hour",8), rpad("Timestamp",28), rpad("Demand (GW)",14),
        rpad("Gen (GW)",12), "Deficit (GW)")
println("  ", "-"^70)
worst_hrs = sortperm(deficit, rev=true)[1:10]
for (rank, t) in enumerate(worst_hrs)
    ts = start_ts + Hour(t-1)
    println("  ", rpad(t,8), rpad(string(ts),28),
            rpad(round(sys_demand[t]/1000,digits=1),14),
            rpad(round(sys_gen[t]/1000,   digits=1),12),
            round(deficit[t]/1000,digits=1))
end

# ── 4. SHORTFALL HOURS ───────────────────────────────────────────────────────
println()
println("="^65)
println("SHORTFALL ANALYSIS (PRAS mean)")
println("="^65)
sys_sf    = vec(sum(shortfall_res.shortfall_mean, dims=1))
short_hrs = findall(sys_sf .> 0.1)
println("  Total shortfall hours: $(length(short_hrs)) / $N_HOURS")
println("  Mean shortfall at shortfall hours: $(round(mean(sys_sf[short_hrs])/1000, digits=1)) GWh")
println("  Max shortfall hour:  $(round(maximum(sys_sf)/1000, digits=1)) GWh at hour $(argmax(sys_sf))")

# ── 5. STORAGE — BATTERIES ───────────────────────────────────────────────────
println()
println("="^65)
println("BATTERY STORAGE")
println("="^65)
h2_idx         = findfirst(==("GB_H2_storage"), stor_energy_res.storages)
batt_idx       = setdiff(1:length(stor_energy_res.storages), [h2_idx])
batt_soc       = vec(sum(stor_energy_res.energy_mean[batt_idx, :], dims=1))
h2_soc         = vec(stor_energy_res.energy_mean[h2_idx, :])
total_batt_cap      = sum(Float64.(sys.storages.energy_capacity[batt_idx, 1]))
total_batt_chg_mw   = sum(Float64.(sys.storages.charge_capacity[batt_idx, 1]))
total_batt_dsch_mw  = sum(Float64.(sys.storages.discharge_capacity[batt_idx, 1]))
delta_batt          = diff(batt_soc)
batt_charged        = sum(max.(delta_batt, 0.0))
batt_discharged     = sum(abs.(min.(delta_batt, 0.0)))

println("  Total battery energy capacity:    $(round(total_batt_cap/1000,    digits=1)) GWh")
println("  Total battery charge capacity:    $(round(total_batt_chg_mw/1000, digits=1)) GW")
println("  Total battery discharge capacity: $(round(total_batt_dsch_mw/1000,digits=1)) GW")
println("  Annual energy charged:            $(round(batt_charged/1e6,    digits=2)) TWh")
println("  Annual energy discharged:         $(round(batt_discharged/1e6, digits=2)) TWh")
println("  Mean SOC all year:                $(round(mean(batt_soc)/1000, digits=1)) GWh  ($(round(100*mean(batt_soc)/total_batt_cap,digits=1))%)")
println("  Mean SOC at shortfall hours:      $(isempty(short_hrs) ? "N/A (zero shortfall)" : string(round(mean(batt_soc[short_hrs])/1000, digits=1)) * " GWh  (" * string(round(100*mean(batt_soc[short_hrs])/total_batt_cap,digits=1)) * "%)")")
println("  Min SOC at shortfall:             $(isempty(short_hrs) ? "N/A (zero shortfall)" : string(round(minimum(batt_soc[short_hrs])/1000, digits=2)) * " GWh")")

# ── 6. STORAGE — HYDROGEN ────────────────────────────────────────────────────
println()
println("="^65)
println("HYDROGEN STORAGE")
println("="^65)
delta_h2        = diff(h2_soc)
h2_charged      = sum(max.(delta_h2, 0.0))
h2_discharged   = sum(abs.(min.(delta_h2, 0.0)))
h2_stor_idx     = findfirst(==("GB_H2_storage"), String.(sys.storages.names))
h2_chg_cap_mw   = sys.storages.charge_capacity[h2_stor_idx, 1]
h2_dsch_cap_mw  = sys.storages.discharge_capacity[h2_stor_idx, 1]
h2_energy_cap   = sys.storages.energy_capacity[h2_stor_idx, 1]
println("  H2 energy capacity:               $(round(h2_energy_cap/1000,  digits=1)) GWh")
println("  H2 charge capacity (electrolysis):$(round(h2_chg_cap_mw/1000,  digits=1)) GW")
println("  H2 discharge capacity (turbines): $(round(h2_dsch_cap_mw/1000, digits=1)) GW")
println("  H2 initial SOC:                   $(round(h2_soc[1]/1000, digits=1)) GWh  ($(round(100*h2_soc[1]/h2_energy_cap, digits=1))%)")
println("  H2 mean SOC all year:             $(round(mean(h2_soc)/1000, digits=1)) GWh  ($(round(100*mean(h2_soc)/h2_energy_cap, digits=1))%)")
println("  H2 mean SOC at shortfall:         $(isempty(short_hrs) ? "N/A (zero shortfall)" : string(round(mean(h2_soc[short_hrs])/1000, digits=1)) * " GWh  (" * string(round(100*mean(h2_soc[short_hrs])/h2_energy_cap, digits=1)) * "%)")")
println("  Annual energy charged into H2:    $(round(h2_charged/1e6,    digits=2)) TWh")
println("  Annual energy discharged from H2: $(round(h2_discharged/1e6, digits=2)) TWh")

short_hrs_adj = short_hrs[short_hrs .< N_HOURS]
n_disch = isempty(short_hrs_adj) ? 0 : sum(delta_h2[short_hrs_adj] .< -10)
n_stat  = isempty(short_hrs_adj) ? 0 : sum(abs.(delta_h2[short_hrs_adj]) .<= 10)
n_charg = isempty(short_hrs_adj) ? 0 : sum(delta_h2[short_hrs_adj] .>  10)
println("  H2 behaviour during shortfall:")
println("    Discharging: $n_disch hrs  |  Static: $n_stat hrs  |  Charging: $n_charg hrs")

# ── 7. INTERFACE FLOWS ───────────────────────────────────────────────────────
println()
println("="^65)
println("INTERFACE UTILISATION DURING SHORTFALL")
println("="^65)
iface_from = sys.interfaces.regions_from
iface_to   = sys.interfaces.regions_to
iface_fwd  = sys.interfaces.limit_forward
iface_bwd  = sys.interfaces.limit_backward
flow_mean  = flow_res.flow_mean
n_ifaces   = size(flow_mean, 1)

println("  ", rpad("i",5), rpad("From",8), rpad("To",10),
        rpad("Cap→(MW)",12), rpad("Cap←(MW)",12),
        rpad("Flow@SF(MW)",14), "Util%")
println("  ", "-"^65)
for i in 1:n_ifaces
    fz  = zone_names[iface_from[i]]
    tz  = zone_names[iface_to[i]]
    cf  = iface_fwd[i,1]; cb = iface_bwd[i,1]
    mf  = mean(flow_mean[i, short_hrs])
    util= round(100*abs(mf)/max(cf,cb,1), digits=1)
    println("  ", rpad(i,5), rpad(fz,8), rpad(tz,10),
            rpad(cf,12), rpad(cb,12), rpad(round(mf,digits=0),14), util, "%")
end

# ── 8. H2 CHARGE/DISCHARGE PER INTERFACE ─────────────────────────────────────
println()
println("="^65)
println("H2 CHARGING (ELECTROLYSIS) AND DISCHARGING (TURBINES)")
println("="^65)
h2_ifaces = [i for i in 1:n_ifaces
             if zone_names[iface_to[i]] == "GB_H2" || zone_names[iface_from[i]] == "GB_H2"]

println("  ", rpad("Interface",18), rpad("Elec Cap(MW)",14), rpad("Turb Cap(MW)",14),
        rpad("Charge@SF(MW)",16), rpad("Chg Util%",11),
        rpad("Discharge@SF(MW)",18), "Disch Util%")
println("  ", "-"^100)
tot_ec=0; tot_tc=0; tot_cf=0.0; tot_df=0.0
for i in h2_ifaces
    fz = zone_names[iface_from[i]]; tz = zone_names[iface_to[i]]
    cf = iface_fwd[i,1]; cb = iface_bwd[i,1]
    mf = isempty(short_hrs) ? 0.0 : mean(flow_mean[i, short_hrs])
    chg  = mf > 0 ? round(mf,    digits=1) : 0.0
    dsch = mf < 0 ? round(abs(mf),digits=1) : 0.0
    cu   = cf > 0 ? round(100*chg/cf,  digits=1) : 0.0
    du   = cb > 0 ? round(100*dsch/cb, digits=1) : 0.0
    println("  ", rpad("$fz↔$tz",18), rpad(cf,14), rpad(cb,14),
            rpad(chg,16), rpad(cu,11), rpad(dsch,18), du, "%")
    global tot_ec+=cf; global tot_tc+=cb
    global tot_cf+=chg; global tot_df+=dsch
end
println("  ", rpad("TOTAL",18), rpad(tot_ec,14), rpad(tot_tc,14),
        rpad(round(tot_cf,digits=1),16),
        rpad(round(100*tot_cf/max(tot_ec,1),digits=1),11),
        rpad(round(tot_df,digits=1),18),
        round(100*tot_df/max(tot_tc,1),digits=1), "%")
println()
println("  Total electrolysis (charging) capacity: $(round(tot_ec/1000, digits=2)) GW")
println("  Total H2 turbine (discharge) capacity:  $(round(tot_tc/1000, digits=2)) GW")
println("  H2 covers $(round(100*tot_tc/maximum(deficit),digits=1))% of worst structural deficit")

# ── 9. ZONE EUE ──────────────────────────────────────────────────────────────
println()
println("="^65)
println("ZONE EUE BREAKDOWN")
println("="^65)
zone_eue = vec(sum(shortfall_res.shortfall_mean, dims=2))
h2_zones = Set(["Z3","Z4","Z5","Z10"])
for (i,z) in enumerate(zone_names)
    zone_eue[i] < 1 && continue
    tag = z in h2_zones ? "✓ H2 direct" : z=="GB_H2" ? "(hub)" : "✗ indirect"
    println("  $(rpad(z,8)) $(rpad(round(zone_eue[i]/1000,digits=1),10)) GWh   $tag")
end

# ── 10. SAVE ALL CSVs ────────────────────────────────────────────────────────
println()
println("="^65)
println("SAVING CSVs")
println("="^65)

# Headline
CSV.write(joinpath(ROOT,"$(LABEL)_headline.csv"), DataFrame(
    metric=["Label","EUE (MWh)","EUE std","LOLE (h)","LOLE std","NEUE (ppm)","NEUE std",
            "Demand (TWh)","Generation (TWh)","Gen/demand ratio",
            "Structural deficit hours","Max deficit (GW)","PRAS shortfall hours",
            "H2 charge cap (MW)","H2 discharge cap (MW)",
            "H2 mean SOC at shortfall (GWh)","H2 mean SOC at shortfall (%)",
            "Battery cap (GWh)","Battery mean SOC at shortfall (GWh)","Battery mean SOC at shortfall (%)"],
    value=[LABEL,
           round(eue_val,digits=0), round(eue_std,digits=0),
           round(lole_val,digits=2),round(lole_std,digits=2),
           round(neue_val,digits=0),round(neue_std,digits=0),
           round(total_demand_TWh,digits=1),round(total_gen_TWh,digits=1),
           round(total_gen_TWh/total_demand_TWh,digits=2),
           sum(deficit .> 0), round(maximum(deficit)/1000,digits=1), length(short_hrs),
           tot_ec, tot_tc,
           isempty(short_hrs) ? "N/A" : string(round(mean(h2_soc[short_hrs])/1000,digits=1)),
           isempty(short_hrs) ? "N/A" : string(round(100*mean(h2_soc[short_hrs])/h2_energy_cap,digits=1)),
           round(total_batt_cap/1000,digits=1),
           isempty(short_hrs) ? "N/A" : string(round(mean(batt_soc[short_hrs])/1000,digits=1)),
           isempty(short_hrs) ? "N/A" : string(round(100*mean(batt_soc[short_hrs])/total_batt_cap,digits=1))]
)); println("  Saved: $(LABEL)_headline.csv")

# Worst hours
CSV.write(joinpath(ROOT,"$(LABEL)_worst_hours.csv"), DataFrame(
    rank=1:10, hour=worst_hrs,
    timestamp=[string(start_ts+Hour(t-1)) for t in worst_hrs],
    demand_gw=round.(sys_demand[worst_hrs]/1000,digits=1),
    generation_gw=round.(sys_gen[worst_hrs]/1000,digits=1),
    deficit_gw=round.(deficit[worst_hrs]/1000,digits=1),
)); println("  Saved: $(LABEL)_worst_hours.csv")

# Interface utilisation
CSV.write(joinpath(ROOT,"$(LABEL)_interfaces.csv"), DataFrame(
    id=1:n_ifaces,
    from=[zone_names[iface_from[i]] for i in 1:n_ifaces],
    to=[zone_names[iface_to[i]] for i in 1:n_ifaces],
    cap_fwd=[iface_fwd[i,1] for i in 1:n_ifaces],
    cap_bwd=[iface_bwd[i,1] for i in 1:n_ifaces],
    mean_flow_all=round.([mean(flow_mean[i,:]) for i in 1:n_ifaces],digits=1),
    mean_flow_sf=round.([isempty(short_hrs) ? 0.0 : mean(flow_mean[i,short_hrs]) for i in 1:n_ifaces],digits=1),
    util_pct=round.([isempty(short_hrs) ? 0.0 : 100*abs(mean(flow_mean[i,short_hrs]))/max(iface_fwd[i,1],iface_bwd[i,1],1)
                    for i in 1:n_ifaces],digits=1),
)); println("  Saved: $(LABEL)_interfaces.csv")

# H2 dispatch
h2_rows = [(interface="$(zone_names[iface_from[i]])↔$(zone_names[iface_to[i]])",
    elec_cap_mw=iface_fwd[i,1], turb_cap_mw=iface_bwd[i,1],
    charge_flow_mw=mean(flow_mean[i,short_hrs])>0 ? round(mean(flow_mean[i,short_hrs]),digits=1) : 0.0,
    discharge_flow_mw=mean(flow_mean[i,short_hrs])<0 ? round(abs(mean(flow_mean[i,short_hrs])),digits=1) : 0.0)
    for i in h2_ifaces]
push!(h2_rows,(interface="TOTAL",
    elec_cap_mw=sum(r.elec_cap_mw for r in h2_rows),
    turb_cap_mw=sum(r.turb_cap_mw for r in h2_rows),
    charge_flow_mw=round(sum(r.charge_flow_mw for r in h2_rows),digits=1),
    discharge_flow_mw=round(sum(r.discharge_flow_mw for r in h2_rows),digits=1)))
CSV.write(joinpath(ROOT,"$(LABEL)_h2_dispatch.csv"), DataFrame(h2_rows))
println("  Saved: $(LABEL)_h2_dispatch.csv")

# Battery stats
CSV.write(joinpath(ROOT,"$(LABEL)_battery.csv"), DataFrame(
    metric=["capacity_gwh","charge_capacity_gw","discharge_capacity_gw",
            "annual_charged_twh","annual_discharged_twh",
            "mean_soc_all_gwh","mean_soc_all_pct",
            "mean_soc_shortfall_gwh","mean_soc_shortfall_pct","min_soc_shortfall_gwh"],
    value=[round(total_batt_cap/1000,digits=1),
           round(total_batt_chg_mw/1000,digits=1),
           round(total_batt_dsch_mw/1000,digits=1),
           round(batt_charged/1e6,digits=2), round(batt_discharged/1e6,digits=2),
           round(mean(batt_soc)/1000,digits=1), round(100*mean(batt_soc)/total_batt_cap,digits=1),
           isempty(short_hrs) ? "N/A" : string(round(mean(batt_soc[short_hrs])/1000,digits=1)),
           isempty(short_hrs) ? "N/A" : string(round(100*mean(batt_soc[short_hrs])/total_batt_cap,digits=1)),
           isempty(short_hrs) ? "N/A" : string(round(minimum(batt_soc[short_hrs])/1000,digits=2))]
)); println("  Saved: $(LABEL)_battery.csv")

# Shortfall hour detail
if isempty(short_hrs)
    println("  Skipped: $(LABEL)_shortfall_detail.csv (zero shortfall — no hours to record)")
else
    CSV.write(joinpath(ROOT,"$(LABEL)_shortfall_detail.csv"), DataFrame(
        hour=short_hrs,
        timestamp=[string(start_ts+Hour(t-1)) for t in short_hrs],
        sys_shortfall_mwh=round.(sys_sf[short_hrs],digits=1),
        h2_soc_gwh=round.(h2_soc[short_hrs]/1000,digits=2),
        h2_soc_pct=round.(100*h2_soc[short_hrs]/658421,digits=1),
        battery_soc_gwh=round.(batt_soc[short_hrs]/1000,digits=2),
        battery_soc_pct=round.(100*batt_soc[short_hrs]/total_batt_cap,digits=1),
        gen_gw=round.(sys_gen[short_hrs]/1000,digits=1),
        demand_gw=round.(sys_demand[short_hrs]/1000,digits=1),
        deficit_gw=round.(deficit[short_hrs]/1000,digits=1),
    )); println("  Saved: $(LABEL)_shortfall_detail.csv")
end

# Zone EUE
CSV.write(joinpath(ROOT,"$(LABEL)_zone_eue.csv"), DataFrame(
    zone=zone_names,
    eue_mwh=round.(zone_eue,digits=1),
    eue_gwh=round.(zone_eue/1000,digits=2),
    h2_connected=[z in h2_zones for z in zone_names],
)); println("  Saved: $(LABEL)_zone_eue.csv")

println()
println("="^65)
println("ALL DONE — 7 CSVs saved to: $ROOT")
println("Label: $LABEL")
println("="^65)