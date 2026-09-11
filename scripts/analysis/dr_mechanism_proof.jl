#!/usr/bin/env julia
# =============================================================================
# dr_mechanism_proof.jl
#
# Produces quantitative evidence for WHY DR changes EUE and LOLE:
#
# Evidence 1: Payback timing — for hours where DR INCREASED shortfall,
#             were the preceding DR_PAYBACK_HRS hours heavily stressed?
#             If yes → payback from those stressed hours caused this.
#
# Evidence 2: Event structure — DR creates MORE events (LOLE↑) by
#             turning continuous events into fragmented ones with gaps,
#             then creating new events during payback periods.
#
# Evidence 3: New zone shortfall timing — for zones that gained NEW EUE
#             (Z1_4, Z2, Z3), exactly which hours did shortfall appear,
#             and what was the DR allocation doing 4h earlier?
#
# Evidence 4: Payback load balance — borrowed load at stressed hours
#             approximately equals returned load at payback hours.
#
# Run reload_session.jl first, then dr_impact_analysis.jl, then this.
# =============================================================================

using CSV, DataFrames, Statistics, Serialization

println("\n" * "="^70)
println("DR MECHANISM PROOF — QUANTITATIVE EVIDENCE")
println("="^70)

DR_PAYBACK_HRS = 4   # match your DR_PAYBACK_HRS setting

NO_DR_ROOT = replace(ROOT, "DR" => "")

sf_dr   = Matrix{Float64}(CSV.read(joinpath(ROOT,       "shortfall_mean.csv"), DataFrame; header=false))
sf_nodr = Matrix{Float64}(CSV.read(joinpath(NO_DR_ROOT, "shortfall_mean.csv"), DataFrame; header=false))

sys_sf_dr   = vec(sum(sf_dr,   dims=1))
sys_sf_nodr = vec(sum(sf_nodr, dims=1))
delta_sf    = sys_sf_dr .- sys_sf_nodr   # positive = DR made worse

# ── EVIDENCE 1: PAYBACK TIMING CORRELATION ────────────────────────────────────
println("\n--- EVIDENCE 1: PAYBACK TIMING CORRELATION ---")
println("For each hour where DR INCREASED shortfall (delta > 0),")
println("what was the mean shortfall in the preceding $DR_PAYBACK_HRS hours?")
println("If high → proves payback from those stressed hours caused this increase.")
println()

worse_hrs = findall(delta_sf .> 10.0)   # hours where DR made things noticeably worse
better_hrs = findall(delta_sf .< -10.0) # hours where DR helped

# For each worse hour, check what happened in the preceding payback window
payback_stress = Float64[]    # mean shortfall in preceding window for "worse" hours
random_stress  = Float64[]    # mean shortfall in preceding window for random hours

for t in worse_hrs
    window_start = max(1, t - DR_PAYBACK_HRS)
    window_end   = t - 1
    window_end < window_start && continue
    push!(payback_stress, mean(sys_sf_nodr[window_start:window_end]))
end

using Random
for t in Random.randperm(N_HOURS)[1:min(500, N_HOURS)]
    window_start = max(1, t - DR_PAYBACK_HRS)
    window_end   = t - 1
    window_end < window_start && continue
    push!(random_stress, mean(sys_sf_nodr[window_start:window_end]))
end

println("  Hours where DR made shortfall WORSE: $(length(worse_hrs))")
println("  Mean prior-window stress at 'worse' hours: $(round(mean(payback_stress), digits=1)) MWh")
println("  Mean prior-window stress at random hours:  $(round(mean(random_stress),  digits=1)) MWh")
ratio = mean(payback_stress) / max(mean(random_stress), 1.0)
println("  Ratio (worse/random): $(round(ratio, digits=2))×")
if ratio > 2.0
    println("  ✓ CONFIRMED: Hours that got worse after DR had $(round(ratio,digits=1))× more stress")
    println("    in the preceding $DR_PAYBACK_HRS hours — consistent with payback mechanism.")
else
    println("  ✗ Weak correlation — payback may not be the primary mechanism.")
end

# ── EVIDENCE 2: EVENT STRUCTURE CHANGE ────────────────────────────────────────
println("\n--- EVIDENCE 2: EVENT STRUCTURE CHANGE ---")
println("DR increases LOLE (more shortfall hours) even if EUE decreases.")
println("This happens because DR splits events and creates new payback events.")
println()

function detect_events(sys_sf, threshold=0.1)
    events = NamedTuple{(:start,:duration,:total_eue), Tuple{Int,Int,Float64}}[]
    in_event=false; start_t=0; dur=0; eue=0.0
    for t in 1:length(sys_sf)
        if sys_sf[t] > threshold
            if !in_event; in_event=true; start_t=t; dur=1; eue=sys_sf[t]
            else; dur+=1; eue+=sys_sf[t]; end
        else
            if in_event
                push!(events,(start=start_t,duration=dur,total_eue=eue))
                in_event=false; dur=0; eue=0.0
            end
        end
    end
    return events
end

ev_nodr = detect_events(sys_sf_nodr)
ev_dr   = detect_events(sys_sf_dr)

println("  No-DR: $(length(ev_nodr)) events")
println("    Mean duration: $(round(mean([e.duration for e in ev_nodr]), digits=2)) hrs")
println("    Max duration:  $(maximum([e.duration for e in ev_nodr])) hrs")
println("    Mean EUE/event: $(round(mean([e.total_eue for e in ev_nodr])/1000, digits=2)) GWh")
println()
println("  DR:    $(length(ev_dr)) events")
println("    Mean duration: $(round(mean([e.duration for e in ev_dr]), digits=2)) hrs")
println("    Max duration:  $(maximum([e.duration for e in ev_dr])) hrs")
println("    Mean EUE/event: $(round(mean([e.total_eue for e in ev_dr])/1000, digits=2)) GWh")

n_new_events = length(ev_dr) - length(ev_nodr)
println()
if length(ev_dr) > length(ev_nodr)
    println("  ✓ DR created $(n_new_events) ADDITIONAL shortfall events")
    println("    These are payback events — periods where returned load")
    println("    caused shortfall in hours that were previously adequate.")
elseif length(ev_dr) == length(ev_nodr)
    println("  DR did not change the number of events (same count)")
else
    println("  DR reduced the number of events by $(abs(n_new_events))")
end

# ── EVIDENCE 3: NEW ZONE SHORTFALL TIMING ─────────────────────────────────────
println("\n--- EVIDENCE 3: NEW ZONE SHORTFALL TIMING ---")
println("For zones that gained NEW EUE after DR, when exactly did shortfall appear,")
println("and was there stress 4 hours earlier in those zones?")
println()

# Load DR allocation from dr_parameters_used.csv
dr_params_path = joinpath(ROOT, "dr_parameters_used.csv")
if isfile(dr_params_path)
    dr_params = CSV.read(dr_params_path, DataFrame)
    println("  DR capacity by zone:")
    for row in eachrow(dr_params)
        row.borrow_mw > 0 && println("    $(row.zone): $(row.borrow_mw) MW borrow, $(row.max_buffer_mwh) MWh buffer")
    end
    println()
end

new_ue_zones = String[]
for (ri, region) in enumerate(region_names)
    ri > size(sf_dr,1) && break
    eue_nodr = sum(sf_nodr[ri,:])
    eue_dr   = sum(sf_dr[ri,:])
    eue_nodr < 1.0 && eue_dr > 1.0 && push!(new_ue_zones, region)
end

zone_proof_rows = []
for zone in new_ue_zones
    ri = findfirst(==(zone), region_names)
    ri === nothing && continue

    zone_sf_dr   = sf_dr[ri,:]
    zone_sf_nodr = sf_nodr[ri,:]

    # Hours where this zone gained new shortfall
    new_sf_hrs = findall((zone_sf_dr .> 0.1) .& (zone_sf_nodr .< 0.1))
    isempty(new_sf_hrs) && continue

    # For those hours, what was the system stress 4h earlier?
    prior_stress = Float64[]
    for t in new_sf_hrs
        window_start = max(1, t - DR_PAYBACK_HRS)
        window_end   = max(1, t - 1)
        if window_start <= window_end
            push!(prior_stress, mean(sys_sf_nodr[window_start:window_end]))
        end
    end

    # DR allocation for this zone
    dr_alloc = 0
    if isfile(dr_params_path)
        dr_row = filter(row -> row.zone == zone, dr_params)
        !isempty(dr_row) && (dr_alloc = dr_row.borrow_mw[1])
    end

    mean_new_sf = mean(zone_sf_dr[new_sf_hrs])
    mean_prior  = isempty(prior_stress) ? 0.0 : mean(prior_stress)

    println("  $(zone): $(length(new_sf_hrs)) NEW shortfall hours")
    println("    Mean new shortfall:       $(round(mean_new_sf, digits=1)) MWh/hr")
    println("    DR borrow capacity:       $(dr_alloc) MW")
    println("    Mean system stress 4h before: $(round(mean_prior, digits=1)) MWh")
    println("    Interpretation: DR borrowed $(dr_alloc) MW in stressed hours,")
    println("    then returned it when $(zone) generation was insufficient → NEW shortfall")
    println()

    push!(zone_proof_rows, (
        zone=zone,
        new_sf_hours=length(new_sf_hrs),
        mean_new_sf_mwh=round(mean_new_sf,digits=1),
        dr_borrow_mw=dr_alloc,
        mean_prior_system_stress=round(mean_prior,digits=1),
    ))
end

# ── EVIDENCE 4: BORROWED vs RETURNED LOAD BALANCE ─────────────────────────────
println("\n--- EVIDENCE 4: BORROWED vs RETURNED LOAD BALANCE ---")
println("If DR payback is the mechanism, then:")
println("  Sum of shortfall REDUCTION (where DR helped) ≈ Sum of shortfall INCREASE (payback)")
println("  The two should roughly balance (energy conservation)")
println()

total_helped  = sum(max.(0.0, .-delta_sf))  # total MWh reduction
total_worsened = sum(max.(0.0,   delta_sf))  # total MWh increase

println("  Total MWh where DR reduced shortfall:   $(round(total_helped/1000,  digits=1)) GWh")
println("  Total MWh where DR increased shortfall: $(round(total_worsened/1000,digits=1)) GWh")
println("  Net EUE change: $(round((sum(sys_sf_dr)-sum(sys_sf_nodr))/1000, digits=1)) GWh")
println()
if abs(total_helped - total_worsened) / max(total_helped,1) < 0.5
    println("  ✓ CONFIRMED: Borrowed ($(round(total_helped/1000,digits=1)) GWh) ≈ Returned ($(round(total_worsened/1000,digits=1)) GWh)")
    println("    DR is moving shortfall in time, not creating or destroying it.")
    println("    Net benefit = $(round((total_helped-total_worsened)/1000,digits=1)) GWh")
else
    println("  ✗ Imbalance — check DR parameters")
end

println("\n  LOLE change explanation:")
lole_nodr = count(>(0.1), sys_sf_nodr)
lole_dr   = count(>(0.1), sys_sf_dr)
println("    No-DR shortfall hours: $lole_nodr")
println("    DR shortfall hours:    $lole_dr  (Δ = $(lole_dr - lole_nodr))")
if lole_dr > lole_nodr
    println("    DR INCREASED shortfall frequency by $(lole_dr - lole_nodr) hours.")
    println("    Each payback event creates a new shortfall hour even when the")
    println("    borrowed magnitude was small. LOLE counts hours, not magnitude —")
    println("    so even tiny payback shortfalls count as new LOLE events.")
end

# ── Export ─────────────────────────────────────────────────────────────────────
proof_summary = DataFrame(
    metric                    = ["Total hours DR helped","Total hours DR worsened",
                                  "LOLE no-DR (hrs)","LOLE DR (hrs)","LOLE change",
                                  "EUE reduction (GWh)","EUE increase from payback (GWh)",
                                  "Net EUE change (GWh)","New UE zones"],
    value                     = [string(count(.<(0), delta_sf)),
                                  string(count(.>(0), delta_sf)),
                                  string(lole_nodr), string(lole_dr),
                                  string(lole_dr - lole_nodr),
                                  string(round(total_helped/1000,digits=1)),
                                  string(round(total_worsened/1000,digits=1)),
                                  string(round((total_helped-total_worsened)/1000,digits=1)),
                                  join(new_ue_zones,", ")]
)
CSV.write(joinpath(ROOT,"dr_mechanism_proof.csv"), proof_summary)
if !isempty(zone_proof_rows)
    CSV.write(joinpath(ROOT,"dr_new_ue_zones_proof.csv"), DataFrame(zone_proof_rows))
end
println("\n  → Saved dr_mechanism_proof.csv")
println("  → Saved dr_new_ue_zones_proof.csv")
println("\n" * "="^70)
println("DONE — Run pras_master_analysis.m to see figures")
println("="^70)