using MultiComponentFlash
export MultiPhaseCompositionalSystemLV
export StandardVolumeSource, VolumeSource, MassSource

const MINIMUM_COMPOSITIONAL_SATURATION = 1e-10

include("variables/variables.jl")
include("utils.jl")
include("flux.jl")
include("sources.jl")
include("wells.jl")

function select_primary_variables!(S, system::CompositionalSystem, model)
    S[:Pressure] = Pressure()
    S[:OverallMoleFractions] = OverallMoleFractions(dz_max = 0.1)
    if has_other_phase(system)
        S[:ImmiscibleSaturation] = ImmiscibleSaturation(ds_max = 0.2)
    end
end

function select_secondary_variables!(S, system::CompositionalSystem, model)
    select_default_darcy_secondary_variables!(S, model.domain, system, model.formulation)
    if has_other_phase(system)
        water_pvt = ConstMuBTable(DEFAULT_MINIMUM_PRESSURE, 1.0, 1e-18, 1e-3, 1e-20)
        set_secondary_variables!(model, PhaseViscosities = ThreePhaseLBCViscositiesLV(water_pvt),
                                        PhaseMassDensities = ThreePhaseCompositionalDensitiesLV(water_pvt))
    else
        set_secondary_variables!(model, PhaseViscosities = LBCViscosities(),
                                        PhaseMassDensities = TwoPhaseCompositionalDensities())
    end
    S[:LiquidMassFractions] = PhaseMassFractions(:liquid)
    S[:VaporMassFractions] = PhaseMassFractions(:vapor)
    S[:FlashResults] = FlashResults(system)
    S[:Saturations] = Saturations()
end

function select_parameters!(prm, system::CompositionalSystem, model)
    select_default_darcy_parameters!(prm, model.domain, system, model.formulation)
    prm[:Temperature] = Temperature()
end

function convergence_criterion(model::CompositionalModel, storage, eq::ConservationLaw, eq_s, r; dt = 1)
    tm = storage.state0.TotalMasses
    a = active_entities(model.domain, Cells())
    function scale(i)
        @inbounds c = a[i]
        t = 0.0
        @inbounds for i in axes(tm, 1)
            t += tm[i, c]
        end
        return t
    end
    @tullio max e[j] := abs(r[j, i]) * dt / scale(i)
    names = model.system.components
    R = (CNV = (errors = e, names = names), )
    return R
end


function convergence_criterion(model::SimulationModel{<:Any, S}, storage, eq::ConservationLaw, eq_s, r; dt = 1) where S<:MultiPhaseCompositionalSystemLV
    sys = model.system
    active = active_entities(model.domain, Cells())
    nc = number_of_components(sys)
    get_sat(ph) = as_value(view(storage.state.Saturations, ph, :))
    get_density(ph) = as_value(view(storage.state.PhaseMassDensities, ph, :))
    if has_other_phase(sys)
        a, l, v = phase_indices(sys)
        sw = get_density(a)
        water_density = get_density(a)
    else
        l, v = phase_indices(sys)
        sw = nothing
        water_density = nothing
    end
    liquid_density = get_density(l)
    vapor_density = get_density(v)

    sl = get_sat(l)
    sv = get_sat(v)
    vol = as_value(storage.state.FluidVolume)

    w = map(x -> x.mw, sys.equation_of_state.mixture.properties)
    e = compositional_criterion(dt, active, r, nc, w, sl, liquid_density, sv, vapor_density, sw, water_density, vol)
    names = model.system.components
    R = (CNV = (errors = e, names = names), )
    return R
end


function compositional_residual_scale(cell, dt, w, sl, liquid_density, sv, vapor_density, sw, water_density, vol)
    if isnothing(sw)
        sw_i = 0.0
    else
        sw_i = sw[cell]
    end
    sat_scale(::Nothing) = 1.0
    sat_scale(sw) = 1.0 - sw[cell]

    total_density = liquid_density[cell] * sl[cell] + vapor_density[cell] * sv[cell]
    return sum(w) * (dt/vol[cell]) * sat_scale(sw) / max(total_density, 1e-3)
end


function compositional_criterion(dt, active, r, nc, w, sl, liquid_density, sv, vapor_density, sw, water_density, vol)
    e = fill(-Inf, nc)
    s_max = 0
    for (ix, i) in enumerate(active)
        scaling = compositional_residual_scale(i, dt, w, sl, liquid_density, sv, vapor_density, sw, water_density, vol)
        for c in 1:(nc-1)
            val = scaling*abs(r[c, ix])/w[c]
            if val > e[c]
                e[c] = val
            end
        end
        valw = dt*abs(r[end, ix])/(water_density[i]*vol[i])
        if valw > e[end]
            e[end] = valw
        end
    end
    return e
end

function compositional_criterion(dt, total_mass0, active, r, nc, w, water::Nothing, ::Nothing, vol)
    # TODO: Fix for updated criterion.
    e = zeros(nc)
    for (ix, i) in enumerate(active)
        s = compositional_residual_scale(i, dt, w, total_mass0)
        for c in 1:nc
            e[c] = max(e[c], s*abs(r[c, ix])/w[c])
        end
    end
    return e
end
