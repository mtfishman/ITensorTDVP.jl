using DifferentialEquations
using ITensors
using ITensorTDVP
using KrylovKit
using LinearAlgebra
using Test

include(joinpath(pkgdir(ITensorTDVP), "examples", "03_models.jl"))
include(joinpath(pkgdir(ITensorTDVP), "examples", "03_solvers.jl"))

# Functions need to be defined in global scope (outside
# of the @testset macro)

ω₁ = 0.1
ω₂ = 0.2

ode_alg = Tsit5()
ode_kwargs = (; reltol=1e-8, abstol=1e-8)

ω⃗ = [ω₁, ω₂]
f⃗ = [t -> cos(ω * t) for ω in ω⃗]

function ode_solver(H⃗₀, time_step, ψ₀; kwargs...)
  return ode_solver(
    -im * TimeDependentSum(f⃗, H⃗₀),
    time_step,
    ψ₀;
    solver_alg=ode_alg,
    ode_kwargs...,
    kwargs...,
  )
end

krylov_kwargs = (; tol=1e-8, eager=true)

function krylov_solver(H⃗₀, time_step, ψ₀; kwargs...)
  return krylov_solver(
    -im * TimeDependentSum(f⃗, H⃗₀), time_step, ψ₀; krylov_kwargs..., kwargs...
  )
end

@testset "Time dependent Hamiltonian" begin
  n = 4
  J₁ = 1.0
  J₂ = 0.1

  time_step = 0.1
  time_stop = 1.0

  nsite = 2
  maxdim = 100
  cutoff = 1e-8

  s = siteinds("S=1/2", n)
  ℋ₁₀ = heisenberg(n; J=J₁, J2=0.0)
  ℋ₂₀ = heisenberg(n; J=0.0, J2=J₂)
  ℋ⃗₀ = [ℋ₁₀, ℋ₂₀]
  H⃗₀ = [MPO(ℋ₀, s) for ℋ₀ in ℋ⃗₀]

  ψ₀ = complex.(MPS(s, j -> isodd(j) ? "↑" : "↓"))

  ψₜ_ode, info_ode = tdvp(ode_solver, H⃗₀, time_stop, ψ₀; time_step, maxdim, cutoff, nsite)

  ψₜ_krylov, info_krylov = tdvp(krylov_solver, H⃗₀, time_stop, ψ₀; time_step, cutoff, nsite)

  ψₜ_full, _ = ode_solver(prod.(H⃗₀), time_stop, prod(ψ₀))

  @test norm(ψ₀) ≈ 1
  @test norm(ψₜ_ode) ≈ 1
  @test norm(ψₜ_krylov) ≈ 1
  @test norm(ψₜ_full) ≈ 1
  @test info_ode.converged == -1
  @test info_krylov.converged == 1

  ode_err = norm(prod(ψₜ_ode) - ψₜ_full)
  krylov_err = norm(prod(ψₜ_krylov) - ψₜ_full)

  @test krylov_err > ode_err
  @test ode_err < 1e-3
  @test krylov_err < 1e-3
end

nothing
