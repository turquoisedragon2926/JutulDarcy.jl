
function plot_well!

end

"""
    plot_well_results(wr::WellResults)
    plot_well_results(v::Vector{WellResults})

Launch interactive viewer for well results. Needs GLMakie to be loaded.
"""
function plot_well_results

end

"""
    plot_reservoir_simulation_result(model::MultiModel, res::ReservoirSimResult; wells = true, reservoir = true)

Plot a reservoir simulation result. If `wells=true` well curves will be shown
interactively. If `reservoir=true` the reservoir quantities will be visualized
in 3D. These options can be combined.
"""
function plot_reservoir_simulation_result(model::MultiModel, res::ReservoirSimResult; wells = true, reservoir = true)
    Jutul.check_plotting_availability()
    if reservoir
        rmodel = reservoir_model(model)
        fig = plot_interactive(rmodel, res.states)
        g = physical_representation(rmodel.data_domain)
        ax = fig.current_axis[]
        for (k, m) in pairs(model.models)
            w = physical_representation(m.data_domain)
            if w isa WellDomain
                plot_well!(ax, g, w)
            end
        end
    else
        fig = nothing
    end
    if wells
        plot_well_results(res.wells, res.time, new_window = true)
    end
    if reservoir
        display(fig)
    end
    return fig
end

"""
    plot_reservoir(model, states=missing; well_fontsize = 18, well_linewidth = 3, kwarg...)

Launch interactive plotter of reservoir + well trajectories in reservoir. Requires GLMakie.
"""
function plot_reservoir(model, arg...;
        gui = true,
        well_fontsize = 18,
        well_linewidth = 3,
        aspect = (1.0, 1.0, 1/3),
        kwarg...
    )
    rmodel = reservoir_model(model)
    data_domain = rmodel.data_domain
    cell_centroids = data_domain[:cell_centroids]
    if haskey(data_domain, :boundary_centroids)
        bc = data_domain[:boundary_centroids]
        if size(bc, 1) == 3
            zb = data_domain[:boundary_centroids][3, :]
            filter!(isfinite, zb)
            if length(zb) > 1
                bounds_z = (minimum(zb), maximum(zb))
            else
                bounds_z = missing
            end
        else
            bounds_z = missing
        end
    else
        bounds_z = missing
    end
    g = physical_representation(data_domain)

    if gui
        fig = plot_interactive(data_domain, arg...; z_is_depth = true, aspect = aspect, kwarg...)
        ax = fig.current_axis[]
    else
        fig, ax, plt = plot_cell_data(g, arg...; z_is_depth = true, kwarg...)
    end
    wells = Dict{Symbol, Any}()
    if model isa MultiModel
        for (k, m) in pairs(model.models)
            w = physical_representation(m.data_domain)
            if w isa WellDomain
                wells[k] = w
            end
        end

        i = 1
        n = length(wells)
        for (k, w) in pairs(wells)
            tf =  0.2 + 0.1*(i/n)
            plot_well!(ax.scene, g, w,
                fontsize = well_fontsize,
                top_factor = tf,
                bounds_z = bounds_z,
                linewidth = well_linewidth,
                cell_centroids = cell_centroids)
            i += 1
        end
    end
    return fig
end

function plot_reservoir(d::DataDomain, arg...;
        aspect = (1.0, 1.0, 1/3),
        gui = true,
        kwarg...
    )
    if gui
        fig = plot_interactive(d, arg...; z_is_depth = true, aspect = aspect, kwarg...)
        ax = fig.current_axis[]
    else
        g = physical_representation(d)
        fig, ax, plt = plot_cell_data(g, arg...; z_is_depth = true, kwarg...)
    end
    return fig
end

function plot_reservoir(case::JutulCase, arg...; kwarg...)
    if length(arg) == 0
        arg = (merge(case.parameters[:Reservoir], case.state0[:Reservoir]),)
    end
    return plot_reservoir(case.model, arg...; kwarg...)
end

"""
    simulate_reservoir_parray(case, mode = :mpi; kwarg...)

Run simulation with parray. This function is primarily for testing.
[`simulate_reservoir`](@ref) can do the same job by passing the correct mode.
"""
function simulate_reservoir_parray(case, mode = :mpi; kwarg...)
    sim, cfg = setup_reservoir_simulator(case; mode = mode, kwarg...)
    return simulate!(sim, case.dt, forces = case.forces, config = cfg)
end

function setup_reservoir_simulator_parray

end
