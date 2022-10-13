function _compute_nsweeps(t; kwargs...)
  time_step::Number = get(kwargs, :time_step, t)
  nsweeps::Union{Int,Nothing} = get(kwargs, :nsweeps, nothing)
  if !isnothing(nsweeps) && time_step != t
    error("Cannot specify both time_step and nsweeps")
  elseif isfinite(time_step) && abs(time_step) > 0.0 && isnothing(nsweeps)
    nsweeps = convert(Int, ceil(abs(t / time_step)))
    if !(nsweeps * time_step ≈ t)
      error("Time step $time_step not commensurate with total time t=$t")
    end
  end

  return nsweeps
end

function _extend_sweeps_param(param, nsweeps)
  if param isa Number
    eparam = fill(param, nsweeps)
  else
    length(param) == nsweeps && return param
    eparam = Vector(undef, nsweeps)
    eparam[1:length(param)] = param
    eparam[(length(param) + 1):end] .= param[end]
  end
  return eparam
end

function process_sweeps(; kwargs...)
  nsweeps = get(kwargs, :nsweeps, 1)
  maxdim = get(kwargs, :maxdim, fill(typemax(Int), nsweeps))
  mindim = get(kwargs, :mindim, fill(1, nsweeps))
  cutoff = get(kwargs, :cutoff, fill(1E-16, nsweeps))
  noise = get(kwargs, :noise, fill(0.0, nsweeps))

  maxdim = _extend_sweeps_param(maxdim, nsweeps)
  mindim = _extend_sweeps_param(mindim, nsweeps)
  cutoff = _extend_sweeps_param(cutoff, nsweeps)
  noise = _extend_sweeps_param(noise, nsweeps)

  return (; maxdim, mindim, cutoff, noise)
end

function alternating_update(solver, PH, t::Number, psi0::MPS; kwargs...)
  reverse_step = get(kwargs, :reverse_step, true)

  nsweeps = _compute_nsweeps(t; kwargs...)
  maxdim, mindim, cutoff, noise = process_sweeps(; nsweeps, kwargs...)

  time_start::Number = get(kwargs, :time_start, 0.0)
  time_step::Number = get(kwargs, :time_step, t)
  order = get(kwargs, :order, 2)
  tdvp_order = TDVPOrder(order, Base.Forward)

  checkdone = get(kwargs, :checkdone, nothing)
  write_when_maxdim_exceeds::Union{Int,Nothing} = get(
    kwargs, :write_when_maxdim_exceeds, nothing
  )
  observer = get(kwargs, :observer!, NoObserver())
  step_observer = get(kwargs, :step_observer!, NoObserver())
  outputlevel::Int = get(kwargs, :outputlevel, 0)

  psi = copy(psi0)

  # Keep track of the start of the current time step.
  # Helpful for tracking the total time, for example
  # when using time-dependent solvers.
  # This will be passed as a keyword argument to the
  # `solver`.
  current_time = time_start

  for sw in 1:nsweeps
    if !isnothing(write_when_maxdim_exceeds) && maxdim[sw] > write_when_maxdim_exceeds
      if outputlevel >= 2
        println(
          "write_when_maxdim_exceeds = $write_when_maxdim_exceeds and maxdim(sweeps, sw) = $(maxdim(sweeps, sw)), writing environment tensors to disk",
        )
      end
      PH = disk(PH)
    end

    sw_time = @elapsed begin
      psi, PH, info = update_step(
        tdvp_order,
        solver,
        PH,
        time_step,
        psi;
        kwargs...,
        current_time,
        reverse_step,
        sweep=sw,
        maxdim=maxdim[sw],
        mindim=mindim[sw],
        cutoff=cutoff[sw],
        noise=noise[sw],
      )
    end

    current_time += time_step

    update!(step_observer; psi, sweep=sw, outputlevel, current_time)

    if outputlevel >= 1
      print("After sweep ", sw, ":")
      print(" maxlinkdim=", maxlinkdim(psi))
      @printf(" maxerr=%.2E", info.maxtruncerr)
      print(" current_time=", round(current_time; digits=3))
      print(" time=", round(sw_time; digits=3))
      println()
      flush(stdout)
    end

    isdone = false
    if !isnothing(checkdone)
      isdone = checkdone(; psi, sweep=sw, outputlevel, kwargs...)
    elseif observer isa ITensors.AbstractObserver
      isdone = checkdone!(observer; psi, sweep=sw, outputlevel)
    end
    isdone && break
  end
  return psi
end

function alternating_update(solver, H::MPO, t::Number, psi0::MPS; kwargs...)
  check_hascommoninds(siteinds, H, psi0)
  check_hascommoninds(siteinds, H, psi0')
  # Permute the indices to have a better memory layout
  # and minimize permutations
  H = ITensors.permute(H, (linkind, siteinds, linkind))
  PH = ProjMPO(H)
  return alternating_update(solver, PH, t, psi0; kwargs...)
end

# Some alternate versions to allow other orderings of arguments:

function alternating_update(solver, t::Number, H, psi0::MPS; kwargs...)
  return alternating_update(solver, H, t, psi0; kwargs...)
end

function alternating_update(solver, H, psi0::MPS, t::Number; kwargs...)
  return alternating_update(solver, H, t, psi0; kwargs...)
end

function alternating_update(solver, Hs::Vector{MPO}, t::Number, psi0::MPS; kwargs...)
  for H in Hs
    check_hascommoninds(siteinds, H, psi0)
    check_hascommoninds(siteinds, H, psi0')
  end
  Hs .= ITensors.permute.(Hs, Ref((linkind, siteinds, linkind)))
  PHs = ProjMPOSum(Hs)
  return alternating_update(solver, PHs, t, psi0; kwargs...)
end
