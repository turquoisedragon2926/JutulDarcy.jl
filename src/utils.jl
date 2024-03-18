function reservoir_model(model::SimulationModel; kwarg...)
    return model
end

function reservoir_model(model::MultiModel; kwarg...)
    return reservoir_model(model.models.Reservoir; kwarg...)
end

function reservoir_model(model::Jutul.CompositeModel; type = missing)
    if !ismissing(type)
        model = Jutul.composite_submodel(model, type)
    end
    return model
end

reservoir_storage(model, storage) = storage
reservoir_storage(model::MultiModel, storage) = storage.Reservoir


"""
    reservoir_domain(g; permeability = convert_to_si(0.1, :darcy), porosity = 0.1, kwarg...)

Set up a `DataDomain` instance for given mesh or other representation `g`.
`permeability` and `porosity` are then added to the domain. If scalars are
passed, they are expanded to cover all cells. Arrays are asserted to match all
cells. Permeability is either one value per cell (diagonal scalar), one value
per dimension given in each row (for a diagonal tensor) or a vector that
represents a compact full tensor representation (6 elements in 3D, 3 in 2D).

# Default data and their values

| Name                         | Explanation                                | Unit         | Default |
|------------------------------|--------------------------------------------|--------------|---------|
| `permeability`               | Rock ability to conduct fluid flow         | ``m^2``      | 100 mD  |
| `porosity`                   | Rock void fraction open to flow (0 to 1)   | -            |  0.3    |
| `rock_density`               | Mass density of rock                       | ``kg^3/m^3`` | 2000.0  |
| `rock_heat_capacity`         | Specific heat capacity of rock             | ``J/(kg K)`` | 900.0   |
| `rock_thermal_conductivity`  | Heat conductivity of rock                  | ``W/m K``    | 3.0     |
| `fluid_thermal_conductivity` | Heat conductivity of fluid phases          | ``W/m K``    | 0.6     |
| `component_heat_capacity`    | Specific heat capacity of fluid components | ``J/(kg K)`` | 4184.0  |

Note that the default values are taken to be roughly those of water for fluid
phases and sandstone for those of rock. Choice of values can severely impact
your simulation results - take care to check the values that your physical
system makes use of!
"""
function reservoir_domain(g;
        permeability = convert_to_si(0.1, :darcy),
        porosity = 0.1,
        rock_thermal_conductivity = 3.0, # W/m K (~sandstone)
        fluid_thermal_conductivity = 0.6, # W/m K (~water)
        rock_heat_capacity = 900.0, # ~sandstone
        component_heat_capacity = 4184.0, # ~water
        rock_density = 2000.0,
        diffusion = missing,
        kwarg...
    )
    if !ismissing(diffusion)
        kwarg = (diffusion = diffusion, kwarg...)
    end
    nk = length(permeability)
    nc = number_of_cells(g)
    if nk != nc && permeability isa AbstractVector
        d = dim(g)
        if nk == d || (d == 2 && nk == 3) || (d == 3 && nk == 6)
            permeability = repeat(permeability, 1, nc)
        end
    end
    return DataDomain(g;
        permeability = permeability,
        porosity = porosity,
        rock_thermal_conductivity = rock_thermal_conductivity,
        fluid_thermal_conductivity = fluid_thermal_conductivity,
        rock_density = rock_density,
        kwarg...
    )
end

"""
    reservoir_domain(m::Union{SimulationModel, MultiModel})

Get reservoir domain embedded in model.
"""
function reservoir_domain(m::Union{SimulationModel, MultiModel})
    d = reservoir_model(m).data_domain
    return d::DataDomain
end

"""
    reservoir_domain(case::JutulCase)

Get reservoir domain from a reservoir simulation case.
"""
function reservoir_domain(case::JutulCase)
    return reservoir_domain(case.model)
end

export reservoir_system

function reservoir_system(flow::MultiPhaseSystem; kwarg...)
    reservoir_system(;flow = flow, kwarg...)
end

"""
    reservoir_system(flow = flow_system, thermal = thermal_system)

Set up a [`Jutul.CompositeSystem`](@ref) that combines multiple systems
together. In some terminologies this is refered to as a multi-physics system.
The classical example is to combine a flow system and a thermal system to create
a coupled flow and heat system.
"""
function reservoir_system(; flow = missing, thermal = missing, kwarg...)
    carg = Pair{Symbol, Jutul.JutulSystem}[]
    if !ismissing(flow)
        flow::MultiPhaseSystem
        push!(carg, :flow => flow)
    end
    if !ismissing(thermal)
        thermal::ThermalSystem
        push!(carg, :thermal => thermal)
    end
    for (k, v) in kwarg
        v::Jutul.JutulSystem
        push!(carg, k => v)
    end
    return CompositeSystem(:Reservoir; carg...)
end

"""
    setup_reservoir_model(reservoir, system; wells = [], <keyword arguments>)
    setup_reservoir_model(reservoir, system; wells = [], context = DefaultContext(), reservoir_context = nothing, backend = :csc, <keyword arguments>)

Set up a reservoir `MultiModel` for a given reservoir `DataDomain` typically set
up from  [`reservoir_domain`](@ref) and an optional vector of wells that are
created using [`setup_vertical_well`](@ref) and  [`setup_well`](@ref).

The routine automatically sets up a facility and couples the wells with the
reservoir and that facility.
"""
function setup_reservoir_model(reservoir::DataDomain, system;
        wells = [],
        context = DefaultContext(),
        reservoir_context = nothing,
        general_ad = false,
        backend = :csc,
        extra_outputs = [:LiquidMassFractions, :VaporMassFractions, :Rs, :Rv, :Saturations],
        split_wells = false,
        assemble_wells_together = true,
        extra_out = true,
        dp_max_abs = nothing,
        dp_max_rel = 0.2,
        dp_max_abs_well = convert_to_si(50, :bar),
        dp_max_rel_well = nothing,
        ds_max = 0.2,
        dz_max = 0.2,
        p_min = DEFAULT_MINIMUM_PRESSURE,
        p_max = Inf,
        dr_max = Inf,
        dT_max_rel = nothing,
        dT_max_abs = nothing,
        parameters = Dict{Symbol, Any}(),
        kwarg...
    )
    # List of models (order matters)
    models = OrderedDict{Symbol, Jutul.AbstractSimulationModel}()
    reservoir_context, context = Jutul.select_contexts(
        backend; 
        main_context = reservoir_context,
        context = context,
        kwarg...
    )
    # We first set up the reservoir
    rmodel = SimulationModel(
        reservoir,
        system,
        context = reservoir_context,
        general_ad = general_ad
    )
    set_reservoir_variable_defaults!(rmodel,
        dp_max_abs = dp_max_abs,
        dp_max_rel = dp_max_rel,
        p_min = p_min,
        p_max = p_max,
        dr_max = dr_max,
        ds_max = ds_max,
        dz_max = dz_max,
        dT_max_rel = dT_max_rel,
        dT_max_abs = dT_max_abs
    )

    for k in extra_outputs
        if haskey(rmodel.secondary_variables, k)
            push!(rmodel.output_variables, k)
        end
        unique!(rmodel.output_variables)
    end
    if haskey(reservoir, :diffusion) || haskey(reservoir, :diffusivity)
        rmodel.parameters[:Diffusivities] = Diffusivities()
    end
    models[:Reservoir] = rmodel
    # Then we set up all the wells
    mode = PredictionMode()
    if length(wells) > 0
        for w in wells
            w_domain = DataDomain(w)
            wc = w.perforations.reservoir
            c = map_well_nodes_to_reservoir_cells(w, reservoir)
            for propk in [:temperature, :pvtnum]
                if haskey(reservoir, propk)
                    w_domain[propk] = reservoir[propk][c]
                end
            end
            wname = w.name
            wmodel = SimulationModel(w_domain, system, context = context)
            set_reservoir_variable_defaults!(wmodel,
                dp_max_abs = dp_max_abs_well,
                dp_max_rel = dp_max_rel_well,
                p_min = p_min,
                p_max = p_max,
                dr_max = dr_max,
                ds_max = ds_max,
                dz_max = dz_max,
                dT_max_rel = dT_max_rel,
                dT_max_abs = dT_max_abs
            )
            models[wname] = wmodel
            if split_wells
                wg = WellGroup([wname])
                F = SimulationModel(wg, mode, context = context, data_domain = DataDomain(wg))
                models[Symbol(string(wname)*string(:_ctrl))] = F
            end
        end
        # Add facility that gorups the wells
        if !split_wells
            wg = WellGroup(map(x -> x.name, wells))
            F = SimulationModel(wg, mode, context = context, data_domain = DataDomain(wg))
            models[:Facility] = F
        end
    end

    # Put it all together as multimodel
    model = reservoir_multimodel(models, split_wells = split_wells, assemble_wells_together = assemble_wells_together)
    if extra_out
        parameters = setup_parameters(model, parameters)
        out = (model, parameters)
    else
        out = model
    end
    return out
end

function set_reservoir_variable_defaults!(model; p_min, p_max, dp_max_abs, dp_max_rel, ds_max, dz_max, dr_max, dT_max_rel = nothing, dT_max_abs = nothing)
    # Replace various variables - if they are available
    replace_variables!(model, OverallMoleFractions = OverallMoleFractions(dz_max = dz_max), throw = false)
    replace_variables!(model, Saturations = Saturations(ds_max = ds_max), throw = false)
    replace_variables!(model, Temperature = Temperature(max_rel = dT_max_rel, max_abs = dT_max_abs), throw = false)
    replace_variables!(model, ImmiscibleSaturation = ImmiscibleSaturation(ds_max = ds_max), throw = false)
    replace_variables!(model, BlackOilUnknown = BlackOilUnknown(ds_max = ds_max, dr_max = dr_max), throw = false)

    p_def = Pressure(
        max_abs = dp_max_abs,
        max_rel = dp_max_rel,
        minimum = p_min,
        maximum = p_max
    )
    replace_variables!(model, Pressure = p_def, throw = false)
    return model
end

"""
    setup_reservoir_simulator(models, initializer, parameters = nothing; <keyword arguments>)

# Arguments
- `models`: either a single model or a Dict with the key :Reservoir for multimodels
- `initializer`: used to setup state0, must be compatible with `model`
- `parameters`: initialized parameters, must be compatible with `model` if provided

# Keyword arguments
- `split_wells`: Add facility model to each well (needed for domain decomposition and MPI solves)
- `assemble_wells_together`: Option to split wells into multiple sparse matrices (false argument experimental)
- `specialize=false`: use deep specialization of storage for faster execution, but significantly more compile time

Additional keyword arguments are documented in the version of this function that uses `JutulCase` as the input.
"""
function setup_reservoir_simulator(models, initializer, parameters = nothing;
        specialize = false,
        split_wells = false,
        assemble_wells_together = true,
        kwarg...
    )
    if isa(models, SimulationModel)
        DT = Dict{Symbol, Any}
        models = DT(:Reservoir => models)
        initializer = DT(:Reservoir => initializer)
        if !isnothing(parameters)
            parameters = DT(:Reservoir => parameters)
        end
    end
    # Convert to multi model
    mmodel = reservoir_multimodel(models, specialize = specialize, split_wells = split_wells, assemble_wells_together = assemble_wells_together)
    if isnothing(parameters)
        parameters = setup_parameters(mmodel)
    end
    # Set up simulator itself, containing the initial state
    state0 = setup_state(mmodel, initializer)

    case = JutulCase(mmodel, state0 = state0, parameters = parameters)
    setup_reservoir_simulator(case; kwarg...)
end

function mode_to_backend(mode::Symbol)
    if mode == :mpi
        mode = MPI_PArrayBackend()
    elseif mode == :parray
        mode = Jutul.JuliaPArrayBackend()
    else
        @assert mode == :debug "Mode must be one of :mpi, :parray, :debug, was :$mode"
        mode = Jutul.DebugPArrayBackend()
    end
end

function mode_to_backend(mode::Jutul.PArrayBackend)
    return mode
end

"""
    setup_reservoir_simulator(case::JutulCase; <keyword arguments>)

# Keyword arguments

## Linear solver options

- `linear_solver=:bicgstab`: iterative solver to use (provided model supports
  it). Typical options are `:bicgstab` or `:gmres` Can alternatively pass a
  linear solver instance.
- `precond=:cpr`: preconditioner for iterative solver: Either :cpr or :ilu0.
- `rtol=1e-3`: relative tolerance for linear solver

## Timestepping options

- `initial_dt=3600*24.0`: initial time-step in seconds (one day by default)
- `target_ds=Inf`: target saturation change over a timestep used by timestepper.
- `target_its=8`: target number of nonlinear iterations per time step
- `offset_its=1`: dampening parameter for time step selector where larger values
  lead to more pessimistic estimates.
- `timesteps=:auto`: Set to `:auto` to use automatic timestepping, `:none` for
  no autoamtic timestepping (i.e. try to solve exact report steps)

## Convergence criterions
- `tol_cnv=1e-3`: maximum allowable point-wise error (volume-balance)
- `tol_mb=1e-7`: maximum alllowable integrated error (mass-balance)
- `tol_cnv_well=10*tol_cnv`: maximum allowable point-wise error for well node
  (volume-balance)
- `tol_mb_well=1e4*tol_mb`: maximum alllowable integrated error for well node
  (mass-balance)

## Inherited keyword arguments

Additional keyword arguments come from the base Jutul simulation framework. We
list a few of the most relevant entries here for convenience:
- `info_level =0`: Output level. Set to 0 for minimal output, -1 for no output
  and 1 or more for increasing verbosity.
- `output_path`: Path to write output to.

Additional keyword arguments are passed onto [`simulator_config`](@ref).
"""
function setup_reservoir_simulator(case::JutulCase;
        mode = :default,
        method = :newton,
        precond = :cpr,
        linear_solver = :bicgstab,
        max_timestep = si_unit(:year),
        max_dt = max_timestep,
        rtol = nothing,
        initial_dt = 3600.0*24.0,
        target_ds = Inf,
        target_its = 8,
        offset_its = 1,
        tol_cnv = 1e-3,
        tol_mb = 1e-7,
        info_level = 0,
        tol_cnv_well = 10*tol_cnv,
        tol_mb_well = 1e4*tol_mb,
        tol_dp_well = 1e-3,
        inc_tol_dp_abs = Inf,
        inc_tol_dp_rel = Inf,
        failure_cuts_timestep = true,
        max_timestep_cuts = 25,
        inc_tol_dz = Inf,
        set_linear_solver = true,
        timesteps = :auto,
        presolve_wells = false,
        parray_arg = Dict{Symbol, Any}(),
        linear_solver_arg = Dict{Symbol, Any}(),
        extra_timing_setup = false,
        nldd_partition = missing,
        nldd_arg = Dict{Symbol, Any}(),
        kwarg...
    )
    set_linear_solver = set_linear_solver || linear_solver isa Symbol
    # Handle old kwarg...
    max_timestep = min(max_dt, max_timestep)
    extra_kwarg = Dict{Symbol, Any}()
    # Setup simulator
    sim_kwarg = Dict{Symbol, Any}()
    sim_kwarg[:extra_timing] = extra_timing_setup
    if presolve_wells
        sim_kwarg[:prepare_step_handler] = PrepareStepWellSolver()
    end
    if mode == :default
        # Single-process solve
        if method == :newton
            sim = Simulator(case; sim_kwarg...)
        else
            extra_kwarg[:method] = method
            sim = NLDD.NLDDSimulator(case, nldd_partition; nldd_arg..., sim_kwarg...)
        end
    else
        # MPI/PArray solve
        if method == :newton
            make_sim = (m; kwarg...) -> Simulator(m; sim_kwarg..., kwarg...)
            pbuffer = false
        else
            make_sim = (m; kwarg...) -> NLDD.NLDDSimulator(m; nldd_arg..., sim_kwarg..., kwarg...)
            pbuffer = true
        end
        b = mode_to_backend(mode)
        sim = setup_reservoir_simulator_parray(case, b;
            simulator_constructor = make_sim,
            primary_buffer = pbuffer
        );
    end

    t_base = TimestepSelector(initial_absolute = initial_dt, max = max_dt)
    sel = Vector{Any}()
    push!(sel, t_base)
    if timesteps == :auto || timesteps == :iteration
        if isfinite(target_its)
            t_its = IterationTimestepSelector(target_its, offset = offset_its)
            push!(sel, t_its)
        end

        if isfinite(target_ds)
            @assert mode == :default "target_ds is only supported in serial."
            t_sat = VariableChangeTimestepSelector(
                :Saturations, target_ds, relative = false, reduction = :max, model = :Reservoir
                )
            push!(sel, t_sat)
        end
    else
        @assert isnothing(timesteps) || timesteps == :none
        push!(sel, t_base)
    end
    # Config: Linear solver, timestep selection defaults, etc...
    if set_linear_solver
        if info_level < 1
            v = -1
        else
            v = 0
        end
        if linear_solver isa Symbol
            extra_ls = (solver = linear_solver,)
        else
            extra_ls = NamedTuple()
        end
        extra_kwarg[:linear_solver] = reservoir_linsolve(case.model, precond;
            rtol = rtol,
            extra_ls...,
            linear_solver_arg...,
        )
    elseif isnothing(linear_solver)
        # Nothing
    else
        extra_kwarg[:linear_solver] = linear_solver
    end
    cfg = simulator_config(sim;
        extra_kwarg...,
        timestep_selectors = sel,
        info_level = info_level,
        max_timestep = max_timestep,
        failure_cuts_timestep = failure_cuts_timestep,
        max_timestep_cuts = max_timestep_cuts,
        kwarg...
    )
    set_default_cnv_mb!(cfg, sim,
        tol_cnv = tol_cnv,
        tol_mb = tol_mb,
        tol_cnv_well = tol_cnv_well,
        tol_mb_well = tol_mb_well,
        tol_dp_well = tol_dp_well,
        inc_tol_dp_abs = inc_tol_dp_abs,
        inc_tol_dp_rel = inc_tol_dp_rel,
        inc_tol_dz = inc_tol_dz
        )
    return (sim, cfg)
end


"""
    simulate_reservoir(state0, model, dt;
        parameters = setup_parameters(model),
        restart = false,
        forces = setup_forces(model),
        kwarg...
    )
    simulate_reservoir(case;
        kwarg...
    )

Convenience function for simulating a reservoir model. This function internally
calls [`setup_reservoir_simulator`](@ref), simulates the problem and returns a
[`ReservoirSimResult`](@ref). Keyword arguments are passed onto
[`setup_reservoir_simulator`](@ref) and are documented in that function.

You can optionally unpack this result into the most typical desired outputs:

`wellsols, states = simulate_reservoir(...)`

where `wellsols` contains the well results and `states` the reservoir results
(pressure, saturations and so on, in each cell of the reservoir domain).

# Examples
You can restart/resume simulations by both providing the `output_path` argument
and the `restart` argument:
```
# Automatically restart from last solved step and returning the outputs if the simulation was already solved.
result = simulate_reservoir(state0, model, dt, output_path = "/some/path", restart = true)

# Restart from step 5
result = simulate_reservoir(state0, model, dt, output_path = "/some/path", restart = 5)

# Start from the beginning (default)
result = simulate_reservoir(state0, model, dt, output_path = "/some/path", restart = false)
```

"""
function simulate_reservoir(state0, model, dt;
        parameters = setup_parameters(model),
        restart = false,
        forces = setup_forces(model),
        config = missing,
        kwarg...
    )
    sim, config_new = setup_reservoir_simulator(model, state0, parameters; kwarg...)
    if ismissing(config)
        config = config_new
    end
    result = simulate!(sim, dt, forces = forces, config = config, restart = restart);
    return ReservoirSimResult(model, result, forces; simulator = sim, config = config)
end

function simulate_reservoir(case::JutulCase; config = missing, restart = false, simulator = missing, kwarg...)
    (; model, forces, state0, parameters, dt) = case
    if ismissing(simulator)
        sim, config_new = setup_reservoir_simulator(model, state0, parameters; kwarg...)
        if ismissing(config)
            config = config_new
        end
    else
        sim = simulator
        @assert !ismissing(config) "If simulator is provided, config must also be provided"
    end
    result = simulate!(sim, dt, forces = forces, config = config, restart = restart);
    return ReservoirSimResult(model, result, forces; simulator = sim, config = config)
end

function set_default_cnv_mb!(cfg::JutulConfig, sim::JutulSimulator; kwarg...)
    set_default_cnv_mb!(cfg, sim.model; kwarg...)
end

function set_default_cnv_mb!(cfg, model; kwarg...)
    set_default_cnv_mb_inner!(cfg[:tolerances], model; kwarg...)
end

function set_default_cnv_mb_inner!(tol, model;
        tol_cnv = 1e-3,
        tol_mb = 1e-7,
        tol_mb_well = 1e-3,
        tol_cnv_well = 1e-2,
        tol_dp_well = 1e-3,
        inc_tol_dp_abs = Inf,
        inc_tol_dp_rel = Inf,
        inc_tol_dz = Inf
        )
    sys = model.system
    if model isa Jutul.CompositeModel && hasproperty(model.system.systems, :flow)
        sys = flow_system(model.system)
    end
    if sys isa ImmiscibleSystem || sys isa BlackOilSystem || sys isa CompositionalSystem
        is_well = physical_representation(model) isa WellDomain
        if is_well
            c = tol_cnv_well
            m = tol_mb_well
            tol[:potential_balance] = (AbsMax = tol_dp_well,)
        else
            c = tol_cnv
            m = tol_mb
        end
        tol[:mass_conservation] = (
            CNV = c,
            MB = m,
            increment_dp_abs = inc_tol_dp_abs,
            increment_dp_rel = inc_tol_dp_rel,
            increment_dz = inc_tol_dz
        )
    end
end

function set_default_cnv_mb!(cfg, model::MultiModel; kwarg...)
    for (k, m) in pairs(model.models)
        set_default_cnv_mb_inner!(cfg[:tolerances][k], m; kwarg...)
    end
end

function setup_reservoir_cross_terms!(model::MultiModel)
    rmodel = reservoir_model(model)
    has_composite = rmodel isa Jutul.CompositeModel
    if has_composite
        systems = rmodel.system.systems
        has_flow = haskey(systems, :flow)
        has_thermal = haskey(systems, :thermal)
        conservation = Pair(:flow, :mass_conservation)
        energy = Pair(:thermal, :energy_conservation)
    else
        has_flow = rmodel.system isa MultiPhaseSystem
        has_thermal = !has_flow
        conservation = :mass_conservation
        energy = :energy_conservation
    end
    for (k, m) in pairs(model.models)
        if k == :Reservoir
            # These are set up from wells via symmetry
        elseif m.domain isa WellGroup
            for target_well in m.domain.well_symbols
                if has_flow
                    ct = FacilityFromWellFlowCT(target_well)
                    add_cross_term!(model, ct, target = k, source = target_well, equation = :control_equation)

                    ct = WellFromFacilityFlowCT(target_well)
                    add_cross_term!(model, ct, target = target_well, source = k, equation = conservation)
                end
                if has_thermal
                    ct = WellFromFacilityThermalCT(target_well)
                    add_cross_term!(model, ct, target = target_well, source = k, equation = energy)
                end
            end
        else
            g = physical_representation(m.domain)
            if g isa WellDomain
                WI = vec(g.perforations.WI)
                rc = vec(g.perforations.reservoir)
                wc = vec(g.perforations.self)
                # Put these over in cross term
                if has_flow
                    ct = ReservoirFromWellFlowCT(WI, rc, wc)
                    add_cross_term!(model, ct, target = :Reservoir, source = k, equation = conservation)
                end
                if has_thermal
                    CI = 1000 .* WI
                    ct = ReservoirFromWellThermalCT(CI, WI, rc, wc)
                    add_cross_term!(model, ct, target = :Reservoir, source = k, equation = energy)
                end
            end
        end
    end
end

function reservoir_multimodel(model::MultiModel; kwarg...)
    # The multimodel is a reservoir multimodel if there exists a submodel named Reservoir
    @assert haskey(model.models, :Reservoir)
    return model
end

function reservoir_multimodel(models::AbstractDict; specialize = false, split_wells = false, assemble_wells_together = haskey(models, :Facility))
    res_model = models[:Reservoir]
    is_block(x) = Jutul.is_cell_major(matrix_layout(x.context))
    block_backend = is_block(res_model)
    n = length(models)
    if block_backend && n > 1
        if  !(split_wells == true) || assemble_wells_together
            groups = repeat([2], n)
            for (i, k) in enumerate(keys(models))
                m = models[k]
                if is_block(m)
                    groups[i] = 1
                end
            end
        else
            groups = repeat([1], n)
            gpos = 1
            pos = 2
            wno = 1
            mkeys = collect(keys(models))
            nw = 1
            for (k, m) in models
                if endswith(String(k), "_ctrl")
                    nw += 1
                end
            end
            if split_wells == :threads
                npartition = Threads.nthreads()
            else
                npartition = nw
            end
            p = Jutul.partition_linear(npartition, nw)
            for (k, m) in models
                if k != :Reservoir
                    sk = String(k)
                    if endswith(sk, "_ctrl")
                        wk = Symbol(sk[1:end-5])
                        wpos = findfirst(isequal(wk), mkeys)
                        if false
                            g = pos
                        else
                            g = p[wno]+1
                        end
                        groups[wpos] = g
                        groups[gpos] = g
                        pos += 1
                        wno += 1
                    end
                end
                gpos += 1
            end
        end
        red = :schur_apply
        outer_context = DefaultContext()
    else
        outer_context = models[:Reservoir].context
        groups = nothing
        red = nothing
    end
    models = convert_to_immutable_storage(models)
    model = MultiModel(models, groups = groups, context = outer_context, reduction = red, specialize = specialize)
    setup_reservoir_cross_terms!(model)
    return model
end

"""
    setup_reservoir_state(model, <keyword arguments>)
    # Ex: For immiscible two-phase
    setup_reservoir_state(model, Pressure = 1e5, Saturations = [0.2, 0.8])

Convenience constructor that initializes a state for a `MultiModel` set up using
[`setup_reservoir_model`](@ref). The main convenience over [`setup_state`](@ref)
is only the reservoir initialization values need be provided: wells are
automatically initialized from the connected reservoir cells.

As an alternative to passing keyword arguments, a `Dict{Symbol, Any}` instance
can be sent in as a second, non-keyword argument.
"""
function setup_reservoir_state(model::MultiModel; kwarg...)
    rmodel = reservoir_model(model)
    pvars = collect(keys(Jutul.get_primary_variables(rmodel)))
    res_state = setup_reservoir_state(rmodel; kwarg...)
    # Next, we initialize the wells.
    init = Dict(:Reservoir => res_state)
    perf_subset(v::AbstractVector, i) = v[i]
    perf_subset(v::AbstractMatrix, i) = v[:, i]
    perf_subset(v, i) = v
    for k in keys(model.models)
        if k == :Reservoir
            # Already done
            continue
        end
        W = model.models[k]
        if W.domain isa WellGroup
            # Facility or well group
            init_w = setup_state(W, TotalSurfaceMassRate = 0.0)
        else
            # Wells
            init_w = Dict{Symbol, Any}()
            W = model.models[k]
            wg = physical_representation(W.domain)
            res_c = wg.perforations.reservoir
            if wg isa MultiSegmentWell
                init_w[:TotalMassFlux] = 0.0
            end
            c = map_well_nodes_to_reservoir_cells(wg, rmodel.data_domain)
            for pk in pvars
                pv = res_state[pk]
                init_w[pk] = perf_subset(pv, c)
            end
        end
        init[k] = init_w
    end
    state = setup_state(model, init)
    return state
end

function setup_reservoir_state(model, init)
    return setup_reservoir_state(model; pairs(init)...)
end

function setup_reservoir_state(rmodel::SimulationModel; kwarg...)
    pvars = collect(keys(Jutul.get_primary_variables(rmodel)))
    svars = collect(keys(Jutul.get_secondary_variables(rmodel)))
    np = length(pvars)
    found = Symbol[]
    res_init = Dict{Symbol, Any}()
    for (k, v) in kwarg
        I = findfirst(isequal(k), pvars)
        if isnothing(I)
            if !(k in svars)
                @warn "Recieved primary variable $k, but this is not known to reservoir model... Adding anyway."
            end
        else
            push!(found, k)
        end
        res_init[k] = v
    end
    handle_alternate_primary_variable_spec!(res_init, found, rmodel, rmodel.system)
    if length(found) != length(pvars)
        missing_primary_variables = setdiff(pvars, found)
        @warn "Not all primary variables were initialized for reservoir model." missing_primary_variables
    end
    return setup_state(rmodel, res_init)
end

function handle_alternate_primary_variable_spec!(res_init, found, rmodel, system)
    # Internal utility to handle non-trivial specification of primary variables
    return res_init
end

"""
    setup_reservoir_forces(model; control = nothing, limits = nothing, set_default_limits = true, <keyword arguments>)

Set up driving forces for a reservoir model with wells
"""
function setup_reservoir_forces(model::MultiModel; control = nothing, limits = nothing, set_default_limits = true, kwarg...)
    submodels = model.models
    has_facility = any(x -> isa(x.domain, WellGroup), values(submodels))
    no_well_controls = isnothing(control) && isnothing(limits)
    @assert no_well_controls || has_facility "Model must have facility when well controls are provided."
    if haskey(submodels, :Facility)
        # Unified facility for all wells
        facility = model.models.Facility

        surface_forces = setup_forces(facility,
            control = control,
            limits = limits,
            set_default_limits = set_default_limits
        )
        # Set up forces for the whole model.
        out = setup_forces(model, Facility = surface_forces; kwarg...)
    else
        new_forces = Dict{Symbol, Any}()
        for (k, m) in pairs(submodels)
            if model_or_domain_is_well(m) && !isnothing(control)
                ctrl_symbol = Symbol("$(k)_ctrl")
                @assert haskey(submodels, ctrl_symbol) "Controller for well $k must be present with the name $ctrl_symbol"
                subctrl = Dict{Symbol, Any}()
                subctrl[k] = control[k]
                sublimits = Dict{Symbol, Any}()
                if haskey(sublimits, k)
                    sublimits[k] = limits[k]
                else
                    sublimits[k] = nothing
                end
                facility = submodels[ctrl_symbol]
                new_forces[ctrl_symbol] = setup_forces(facility,
                    control = subctrl,
                    limits = sublimits,
                    set_default_limits = set_default_limits
                )
            end
        end
        out = setup_forces(model; pairs(new_forces)..., kwarg...)
    end
    # If the model is a composite model we need to do some extra work to pass on
    # flow forces with the correct label.
    #
    # TODO: At the moment we have no mechanism for setting up forces for thermal
    # specifically.
    for (k, m) in pairs(submodels)
        f = out[k]
        if m isa Jutul.CompositeModel
            mkeys = keys(m.system.systems)
            tmp = Dict{Symbol, Any}()
            for mk in mkeys
                tmp[mk] = nothing
            end
            tmp[:flow] = f
            out[k] = (; pairs(tmp)...)
        end
    end
    return out
end


"""
    full_well_outputs(model, states, forces; targets = available_well_targets(model.models.Reservoir), shortname = false)

Get the full set of well outputs after a simulation has occured, for plotting or other post-processing.
"""
function full_well_outputs(model, states, forces; targets = available_well_targets(model.models.Reservoir), shortname = false)
    out = Dict()
    if shortname
        tm = :mass
    else
        tm = Symbol("Total surface mass rate")
    end
    for w in well_symbols(model)
        out[w] = Dict()
        for t in targets
            out[w][translate_target_to_symbol(t(1.0), shortname = shortname)] = well_output(model, states, w, forces, t)
        end
        out[w][Symbol(tm)] = well_output(model, states, w, forces, :TotalSurfaceMassRate)
    end
    return out
end

"""
    well_output(model, states, well_symbol, forces, target = BottomHolePressureTarget)

Get a specific well output from a valid operational target once a simulation is completed an `states` are available.
"""
function well_output(model::MultiModel, states, well_symbol, forces, target = BottomHolePressureTarget)
    n = length(states)
    d = zeros(n)

    well_number = 1
    for (k, m) in pairs(model.models)
        if k == well_symbol
            break
        end
        if model_or_domain_is_well(m)
            well_number += 1
        end
    end
    rhoS_o = reference_densities(model.models[well_symbol].system)

    to_target(t::DataType) = t(1.0)
    to_target(t::Type) = t(1.0)
    to_target(t::Symbol) = t

    target_limit = to_target(target)

    well_model = model.models[well_symbol]
    for (i, state) = enumerate(states)
        well_state = state[well_symbol]
        well_state = convert_to_immutable_storage(well_state)
        ctrl_grp = Symbol("$(well_symbol)_ctrl")
        if haskey(state, ctrl_grp)
            q_t = only(state[ctrl_grp][:TotalSurfaceMassRate])
        else
            q_t = state[:Facility][:TotalSurfaceMassRate][well_number]
        end
        if forces isa AbstractVector
            force = forces[i]
        else
            force = forces
        end
        if haskey(force, :outer)
            force = force.outer
        end
        if haskey(force, :Facility)
            gforce = force[:Facility]
        else
            gforce = force[Symbol("$(well_symbol)_ctrl")]
        end
        control = gforce.control[well_symbol]
        if control isa InjectorControl || control isa ProducerControl
            q_t *= control.factor
        end
        if target == :TotalSurfaceMassRate
            d[i] = q_t
        else
            if q_t == 0
                current_control = DisabledControl()
                if target == BottomHolePressureTarget
                    v = well_state.Pressure[1]
                else
                    v = 0.0
                end
                d[i] = v
            else
                current_control = replace_target(control, BottomHolePressureTarget(1.0))
                rhoS, S = surface_density_and_volume_fractions(well_state)
                v = well_target_value(q_t, current_control, target_limit, well_model, well_state, rhoS, S)
                d[i] = v
            end
        end
    end
    return d
end

"""
    well_symbols(model::MultiModel)

Get the keys of a `MultiModel` models that correspond to well models.
"""
function well_symbols(model::MultiModel)
    models = model.models
    symbols = Vector{Symbol}()
    for (k, m) in pairs(models)
        D = m.domain
        if isa(physical_representation(D), WellDomain)
            push!(symbols, k)
        end
    end
    return symbols
end

function wellgroup_symbols(model::MultiModel)
    models = model.models
    symbols = Vector{Symbol}()
    for (k, m) in pairs(models)
        D = m.domain
        if isa(D, WellControllerDomain)
            push!(symbols, k)
        end
    end
    return symbols
end

function available_well_targets(model)
    phases = get_phases(flow_system(model.system))
    targets = [BottomHolePressureTarget, SurfaceLiquidRateTarget, TotalRateTarget]
    if AqueousPhase() in phases
        push!(targets, SurfaceLiquidRateTarget)
        push!(targets, SurfaceWaterRateTarget)
    end
    if LiquidPhase() in phases
        push!(targets, SurfaceLiquidRateTarget)
        push!(targets, SurfaceOilRateTarget)
    end
    if VaporPhase() in phases
        push!(targets, SurfaceGasRateTarget)
    end
    return unique(targets)
end

function partitioner_input(model, parameters; conn = :trans)
    rmodel = reservoir_model(model)
    if haskey(parameters, :Reservoir)
        parameters = parameters[:Reservoir]
    end
    grid = physical_representation(rmodel.domain)

    N = grid.neighborship
    trans = parameters[:Transmissibilities]
    if conn == :trans
        T = copy(trans)
    else
        @assert conn == :unit
        T = ones(Int, length(trans))
    end
    groups = Vector{Vector{Int}}()
    if model isa MultiModel
        for (k, m) in pairs(model.models)
            wg = physical_representation(m.domain)
            if wg isa WellDomain
                rcells = vec(Int.(wg.perforations.reservoir))
                push!(groups, rcells)
            end
        end
    end
    return (N, T, groups)
end

function reservoir_partition(model::MultiModel, p)
    !haskey(model.models, :Facility) || throw(ArgumentError("Cannot partition model if split_wells = false in setup_reservoir_model"))
    p_res = SimplePartition(p)
    models = model.models
    function model_is_well(m)
        d = physical_representation(m.domain)
        return isa(d, JutulDarcy.WellDomain)
    end
    wpart = Dict()
    for key in keys(models)
        m = models[key]
        if model_is_well(m)
            wg = physical_representation(m.domain)
            wc = wg.perforations.reservoir
            unique_part_wcells = unique(p[wc])
            @assert length(unique_part_wcells) == 1 "All cells of well $key must be in the same partitioned block. Found: $unique_part_wcells for cells $wc = $(p[wc])"
            wpart[key] = first(unique_part_wcells)
        end
    end
    part = Dict{Symbol, Any}()
    for key in keys(models)
        m = models[key]
        if key == :Reservoir
            part[key] = p_res
        elseif model_is_well(m)
            part[key] = wpart[key]
        else
            # Well group, probably?
            s = Symbol(string(key)[1:end-5])
            part[key] = wpart[s]
        end
    end
    return SimpleMultiModelPartition(part, :Reservoir)
end

function reservoir_partition(model, p)
    return SimplePartition(p)
end

function Base.iterate(t::ReservoirSimResult)
    return (t.wells, :wells)
end

function Base.iterate(t::ReservoirSimResult, state)
    if state == :states
        return (t.time, nothing)
    else
        @assert state == :wells "Unapck syntax: ws, states, t = res_result"
        return (t.states, :states)
    end
end

Base.lastindex(t::ReservoirSimResult) = :states

function Base.show(io::IO, ::MIME"text/plain", sr::ReservoirSimResult)
    # return 
    function print_keys(prefix, el)
        for k in keys(el)
            v = el[k]
            if v isa AbstractDict
                print(io, "$prefix:$k\n")
                print_keys("  $prefix", v)
            else
                if v isa AbstractVecOrMat
                    s = " of size $(size(v))"
                else
                    s = ""
                end
                print(io, "$prefix:$k => $(typeof(v))$s\n")
            end
        end
    end
    # fmt = raw"u. dd Y H:mm"

    states = sr.states
    n = length(states)
    print(io, sr)
    print(io, ":\n")
    if n > 0
        wk = keys(sr.wells)
        nw = length(wk)
        print(io, "\n  wells ($nw present):\n")
        if nw > 0
            for k in wk
                print(io, "    :$k\n")
            end
            print(io, "    Results per well:\n")
            print_keys("       ", sr.wells[first(wk)])
        end
        el = first(states)
        print(io, "\n  states (Vector with $n entries, reservoir variables for each state)\n")
        print_keys("    ", el)
    end
    print(io, "\n  time (report time for each state)\n     $(typeof(sr.time)) of length $n\n")
    print(io, "\n  result (extended states, reports)\n     $(sr.result)\n")
    extra_keys = keys(sr.extra)
    print(io, "\n  extra\n     $(typeof(sr.extra)) with ")
    if length(extra_keys) == 0
        print(io, "with no data.\n")
    else
        ek = join(extra_keys, ", :")
        print(io, "keys :$ek\n")
    end
    Jutul.print_sim_result_timing(io, sr.result)
end

function Base.show(io::IO, sr::ReservoirSimResult)
    n = length(sr.states)
    if n == 1
        s = "entry"
    else
        s = "entries"
    end
    print(io, "ReservoirSimResult with $n $s")
end

"""
    generate_phase_indices(phases, canonical = (a = AqueousPhase(), l = LiquidPhase(), v = VaporPhase()))

Generate mapping for canonical ordering of phases.
"""
function generate_phase_indices(phases, canonical = (a = AqueousPhase(), l = LiquidPhase(), v = VaporPhase()))
    phase_ind_dict = OrderedDict()
    for (s, ph) in pairs(canonical)
        pos = findfirst(isequal(ph), phases)
        if !isnothing(pos)
            phase_ind_dict[s] = pos
        end
    end
    return NamedTuple(pairs(phase_ind_dict))
end

"""
    reservoir_groups_for_printing(model::MultiModel)

Break down the standard reservoir simulator model into groups based on if they
are the reservoir, wells, facility or something else.
"""
function reservoir_groups_for_printing(model::MultiModel)
    groups = Vector{Tuple{Symbol, Vector{Symbol}}}()

    rgroup = (:Reservoir, [:Reservoir])
    wgroup = (:Wells, Symbol[])
    fgroup = (:Facility, Symbol[])

    push!(groups, rgroup)
    push!(groups, wgroup)
    push!(groups, fgroup)

    for (k, m) in pairs(model.models)
        d = m.domain
        if d isa Jutul.DiscretizedDomain
            d = m.domain.representation
        end
        if k == :Reservoir
            continue
        elseif d isa JutulDarcy.WellDomain
            push!(wgroup[2], k)
        elseif d isa JutulDarcy.WellControllerDomain
            push!(fgroup[2], k)
        else
            push!(groups, (k, [k]))
        end
    end
    return groups
end

"""
    reservoir_transmissibility(d::DataDomain)

Special transmissibility function for reservoir simulation that handles
additional complexity present in industry grade models.
"""
function reservoir_transmissibility(d::DataDomain; version = :xyz)
    g = physical_representation(d)
    N = d[:neighbors]
    nc = number_of_cells(d)
    faces, facepos = get_facepos(N, nc)
    facesigns = Jutul.get_facesigns(N, faces, facepos, nc)

    if version == :ijk
        face_dir = get_ijk_face_dir(g, N)
    else
        face_dir = missing
    end
    T_hf = compute_half_face_trans(
        d[:cell_centroids],
        d[:face_centroids],
        d[:normals],
        d[:areas],
        d[:permeability],
        faces, facepos, facesigns,
        version = version,
        face_dir = face_dir
    )
    neg_count = 0
    for (i, T_hf_i) in enumerate(T_hf)
        neg_count += T_hf_i < 0
        T_hf[i] = abs(T_hf_i)
    end
    if neg_count > 0
        tran_tot = length(T_hf)
        perc = round(100*neg_count/tran_tot, digits = 2)
        jutul_message("Transmissibility", "Replaced $neg_count negative half-transmissibilities (out of $tran_tot, $perc%) with their absolute value.")
    end
    bad_count = 0
    for (i, T_hf_i) in enumerate(T_hf)
        if !isfinite(T_hf_i)
            bad_count += 1
            T_hf[i] = 0.0
        end
    end
    if bad_count > 0
        tran_tot = length(T_hf)
        perc = round(100*bad_count/tran_tot, digits = 2)
        jutul_message("Transmissibility", "Replaced $bad_count non-finite half-transmissibilities (out of $tran_tot, $perc%) with zero.")
    end
    if haskey(d, :net_to_gross)
        # Net to gross applies to vertical trans only
        nf = number_of_faces(d)
        otag = get_mesh_entity_tag(g, Faces(), :orientation, throw = false)
        if !ismissing(otag)
            # Use tags if provided
            face_is_vertical = map(1:nf) do face
                return mesh_entity_has_tag(g, Faces(), :orientation, :vertical, face)
            end
        elseif g isa CartesianMesh
            # Cartesian mesh is simple
            k_index = map(c -> cell_ijk(g, c), 1:nc)
            face_is_vertical = map(1:nf) do face
                l, r = N[:, face]
                return k_index[l] == k_index[r]
            end
        else
            # Fall back to normals
            normals = d[:normals]
            face_is_vertical = map(1:nf) do face
                nx, ny, nz = normals[:, face]
                return abs(nz) < max(abs(nx), abs(ny))
            end
        end
        count = 0
        for (c, ntg) in enumerate(d[:net_to_gross])
            if !(ntg ≈ 1.0)
                count += 1
                for fp in facepos[c]:(facepos[c+1]-1)
                    if face_is_vertical[faces[fp]]
                        T_hf[fp] *= ntg
                    end
                end
            end
        end
    end
    T = compute_face_trans(T_hf, N)
    if haskey(d, :transmissibility_multiplier, Faces())
        tm = d[:transmissibility_multiplier]
        @. T *= tm
    end
    return T
end

function get_ijk_face_dir(g, N)
    nf = number_of_faces(g)
    face_dir = ones(Int, nf)
    ijk_c = map(i -> cell_ijk(g, i), 1:number_of_cells(g))
    gdim = dim(g)
    for i in 1:nf
        l, r = N[:, i]
        ijk_l = ijk_c[l]
        ijk_r = ijk_c[r]
        for j in 1:gdim
            if ijk_l[j] != ijk_r[j]
                face_dir[i] = j
                break
            end
        end
    end
    return face_dir
end

function reservoir_regions(m::MultiModel, arg...; kwarg...)
    rm = reservoir_model(m)
    return reservoir_regions(rm, arg...; kwarg...)
end

function reservoir_regions(m::SimulationModel, arg...; kwarg...)
    return reservoir_regions(m.data_domain, arg...; kwarg...)
end

"""
    reservoir_regions(d::DataDomain, type = :pvtnum)

Get regions stored in `DataDomain`, returning `nothing` if the field is not
found.
"""
function reservoir_regions(d::DataDomain, type = :pvtnum)
    if haskey(d, type, Cells())
        out = d[type]
    else
        out = nothing
    end
    return out
end
