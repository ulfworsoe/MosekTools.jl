# Copyright (c) 2017: Ulf Worsøe, Mosek ApS
#
# Use of this source code is governed by an MIT-style license that can be found
# in the LICENSE.md file or at https://opensource.org/licenses/MIT.

function MOI.get(m::Optimizer, attr::MOI.ObjectiveValue)
    MOI.check_result_index_bounds(m, attr)
    return Mosek.getprimalobj(m.task, m.solutions[attr.result_index].whichsol)
end

function MOI.get(m::Optimizer, attr::MOI.DualObjectiveValue)
    MOI.check_result_index_bounds(m, attr)
    return Mosek.getdualobj(m.task, m.solutions[attr.result_index].whichsol)
end

function MOI.get(m::Optimizer, ::MOI.ObjectiveBound)
    if Mosek.getintinf(m.task, Mosek.MSK_IINF_MIO_OBJ_BOUND_DEFINED) > 0
        return Mosek.getdouinf(m.task, Mosek.MSK_DINF_MIO_OBJ_BOUND)
    elseif MOI.get(m, MOI.DualStatus(1)) == MOI.FEASIBLE_POINT
        return MOI.get(m, MOI.DualObjectiveValue(1))
    end
    return NaN
end

function MOI.get(m::Optimizer, ::MOI.RelativeGap)
    val = MOI.get(m, MOI.ObjectiveValue(1))
    bound = MOI.get(m, MOI.ObjectiveBound())
    return abs(val - bound) / max(1e-10, abs(val))
end

function MOI.get(m::Optimizer, ::MOI.SolveTimeSec)
    return Mosek.getdouinf(m.task, Mosek.MSK_DINF_OPTIMIZER_TIME)
end

function MOI.get(model::Optimizer, ::MOI.ObjectiveSense)
    if model.feasibility
        return MOI.FEASIBILITY_SENSE
    end
    sense = Mosek.getobjsense(model.task)
    if sense == Mosek.MSK_OBJECTIVE_SENSE_MINIMIZE
        return MOI.MIN_SENSE
    else
        return MOI.MAX_SENSE
    end
end

function MOI.set(
    model::Optimizer,
    attr::MOI.ObjectiveSense,
    sense::MOI.OptimizationSense,
)
    if sense == MOI.MIN_SENSE
        model.feasibility = false
        Mosek.putobjsense(model.task, Mosek.MSK_OBJECTIVE_SENSE_MINIMIZE)
    elseif sense == MOI.MAX_SENSE
        model.feasibility = false
        Mosek.putobjsense(model.task, Mosek.MSK_OBJECTIVE_SENSE_MAXIMIZE)
    else
        @assert sense == MOI.FEASIBILITY_SENSE
        model.feasibility = true
        model.has_objective = false
        Mosek.putobjsense(model.task, Mosek.MSK_OBJECTIVE_SENSE_MINIMIZE)
        MOI.set(
            model,
            MOI.ObjectiveFunction{MOI.ScalarAffineFunction{Float64}}(),
            MOI.ScalarAffineFunction(MOI.ScalarAffineTerm{Float64}[], 0.0),
        )
    end
    return
end

#### Solver/Solution information

function MOI.get(m::Optimizer, ::MOI.SimplexIterations)::Int64
    return Mosek.getlintinf(m.task, Mosek.MSK_LIINF_MIO_SIMPLEX_ITER) +
           Mosek.getintinf(m.task, Mosek.MSK_IINF_SIM_PRIMAL_ITER) +
           Mosek.getintinf(m.task, Mosek.MSK_IINF_SIM_DUAL_ITER)
end

function MOI.get(m::Optimizer, ::MOI.BarrierIterations)::Int64
    return Mosek.getlintinf(m.task, Mosek.MSK_LIINF_MIO_INTPNT_ITER) +
           Mosek.getintinf(m.task, Mosek.MSK_IINF_INTPNT_ITER)
end

function MOI.get(m::Optimizer, ::MOI.NodeCount)::Int64
    return Mosek.getintinf(m.task, Mosek.MSK_IINF_MIO_NUM_BRANCH)
end

MOI.get(m::Optimizer, ::MOI.RawSolver) = m.task

MOI.get(m::Optimizer, ::MOI.ResultCount) = length(m.solutions)

#### Problem information

function MOI.get(
    model::Optimizer,
    ::MOI.NumberOfConstraints{F,S},
) where {F<:MOI.AbstractFunction,S<:MOI.AbstractSet}
    return length(MOI.get(model, MOI.ListOfConstraintIndices{F,S}()))
end

function MOI.get(
    model::Optimizer,
    ::MOI.ListOfConstraintIndices{F,S},
) where {F<:MOI.ScalarAffineFunction{Float64},S<:ScalarLinearDomain}
    ret = MOI.ConstraintIndex{F,S}.(allocatedlist(model.c_block))
    filter!(Base.Fix1(MOI.is_valid, model), ret)
    return ret
end

function MOI.get(
    model::Optimizer,
    ::MOI.ListOfConstraintIndices{F,S},
) where {F<:MOI.VariableIndex,S<:Union{ScalarLinearDomain,MOI.Integer}}
    ret = MOI.ConstraintIndex{F,S}.(allocatedlist(model.x_block))
    filter!(Base.Fix1(MOI.is_valid, model), ret)
    return ret
end

function MOI.get(
    model::Optimizer,
    ::MOI.ListOfConstraintIndices{F,S},
) where {F<:MOI.VectorOfVariables,S<:VectorCone}
    ids = eachindex(model.variable_to_vector_constraint_id)
    ret = MOI.ConstraintIndex{F,S}.(ids)
    filter!(Base.Fix1(MOI.is_valid, model), ret)
    return ret
end

function MOI.get(
    model::Optimizer,
    attr::MOI.ListOfConstraintIndices{F,S},
) where {F<:MOI.VectorAffineFunction{Float64},S<:VectorConeDomain}
    ret = MOI.ConstraintIndex{F,S}.(1:Mosek.getnumacc(model.task))
    filter!(Base.Fix1(MOI.is_valid, model), ret)
    return ret
end

function MOI.get(
    model::Optimizer,
    ::MOI.ListOfConstraintIndices{F,S},
) where {F<:MOI.VectorOfVariables,S<:MOI.PositiveSemidefiniteConeTriangle}
    # TODO this only works because deletion of PSD constraints is not supported
    # yet
    return MOI.ConstraintIndex{F,S}.(1:length(model.sd_dim))
end

function MOI.get(model::Optimizer, ::MOI.ListOfConstraintTypesPresent)
    list = Tuple{Type,Type}[]
    for F in (MOI.VariableIndex, MOI.ScalarAffineFunction{Float64})
        for S in (
            MOI.LessThan{Float64},
            MOI.GreaterThan{Float64},
            MOI.EqualTo{Float64},
            MOI.Interval{Float64},
            MOI.Integer,
        )
            if MOI.get(model, MOI.NumberOfConstraints{F,S}()) > 0
                push!(list, (F, S))
            end
        end
    end
    for F in (MOI.VectorOfVariables, MOI.VectorAffineFunction{Float64})
        for S in (
            MOI.SecondOrderCone,
            MOI.RotatedSecondOrderCone,
            MOI.PowerCone{Float64},
            MOI.DualPowerCone{Float64},
            MOI.ExponentialCone,
            MOI.DualExponentialCone,
            MOI.PositiveSemidefiniteConeTriangle,
            MOI.GeometricMeanCone,
            MOI.Scaled{MOI.PositiveSemidefiniteConeTriangle},
        )
            if MOI.get(model, MOI.NumberOfConstraints{F,S}()) > 0
                push!(list, (F, S))
            end
        end
    end
    return list
end

#### Warm start values

function MOI.supports(
    ::Optimizer,
    ::MOI.VariablePrimalStart,
    ::Type{MOI.VariableIndex},
)
    return true
end

function _putxxslice(task::Mosek.MSKtask, col::ColumnIndex, value::Float64)
    for sol in [Mosek.MSK_SOL_BAS, Mosek.MSK_SOL_ITG]
        Mosek.putxxslice(task, sol, col.value, col.value + Int32(1), [value])
    end
    return
end

# TODO(odow): I'm not sure how to warm-start PSD matrices
_putxxslice(::Mosek.MSKtask, ::MatrixIndex, ::Float64) = nothing

function MOI.set(
    m::Optimizer,
    ::MOI.VariablePrimalStart,
    v::MOI.VariableIndex,
    val::Real,
)
    _putxxslice(m.task, mosek_index(m, v), convert(Float64, val))
    m.variable_primal_start[v] = convert(Float64, val)
    return
end

function MOI.set(
    m::Optimizer,
    ::MOI.VariablePrimalStart,
    v::MOI.VariableIndex,
    ::Nothing,
)
    _putxxslice(m.task, mosek_index(m, v), 0.0)
    delete!(m.variable_primal_start, v)
    return
end

function MOI.get(m::Optimizer, ::MOI.VariablePrimalStart, v::MOI.VariableIndex)
    return get(m.variable_primal_start, v, nothing)
end

#### Variable solution values

function _get_variable_primal(m::Optimizer, result_index, col::ColumnIndex)
    return m.solutions[result_index].xx[col.value]
end

function _get_variable_primal(m::Optimizer, result_index, mat::MatrixIndex)
    d = m.sd_dim[mat.matrix]
    r = d - mat.column + 1
    #   #entries full Δ       #entries right Δ      #entries above in lower Δ
    k = div((d + 1) * d, 2) - div((r + 1) * r, 2) + (mat.row - mat.column + 1)
    return m.solutions[result_index].barxj[mat.matrix][k]
end

function MOI.get(m::Optimizer, attr::MOI.VariablePrimal, vi::MOI.VariableIndex)
    MOI.check_result_index_bounds(m, attr)
    return _get_variable_primal(m, attr.result_index, mosek_index(m, vi))
end

function MOI.get!(
    output::Vector{Float64},
    m::Optimizer,
    attr::MOI.VariablePrimal,
    vs::Vector{MOI.VariableIndex},
)
    MOI.check_result_index_bounds(m, attr)
    @assert eachindex(output) == eachindex(vs)
    for i in eachindex(output)
        output[i] = MOI.get(m, attr, vs[i])
    end
    return
end

function MOI.get(
    m::Optimizer,
    attr::MOI.VariablePrimal,
    vs::Vector{MOI.VariableIndex},
)
    MOI.check_result_index_bounds(m, attr)
    output = Vector{Float64}(undef, length(vs))
    MOI.get!(output, m, attr, vs)
    return output
end

#### Variable basis status

function _basis_status_code(status, attr)
    if status == Mosek.MSK_SK_UNK           # (0)
        msg = "The status for the constraint or variable is unknown"
        throw(MOI.GetAttributeNotAllowed(attr, msg))
    elseif status == Mosek.MSK_SK_BAS       # (1)
        return MOI.BASIC
    elseif status == Mosek.MSK_SK_SUPBAS    # (2)
        return MOI.SUPER_BASIC
    elseif status == Mosek.MSK_SK_LOW       # (3)
        return MOI.NONBASIC_AT_LOWER
    elseif status == Mosek.MSK_SK_UPR       # (4)
        return MOI.NONBASIC_AT_UPPER
    elseif status == Mosek.MSK_SK_FIX       # (5)
        return MOI.NONBASIC
    end
    @assert status == Mosek.MSK_SK_INF      # (6)
    msg = "The constraint or variable is infeasible in the bounds"
    return throw(MOI.GetAttributeNotAllowed(attr, msg))
end

function MOI.get(m::Optimizer, attr::MOI.VariableBasisStatus, col::ColumnIndex)
    status = m.solutions[attr.result_index].xxstatus[col.value]
    return _basis_status_code(status, attr)
end

function MOI.get(::Optimizer, attr::MOI.VariableBasisStatus, mat::MatrixIndex)
    msg = "$attr not supported for PSD variable $mat"
    return throw(MOI.GetAttributeNotAllowed(attr, msg))
end

function MOI.get(
    m::Optimizer,
    attr::MOI.VariableBasisStatus,
    vi::MOI.VariableIndex,
)
    MOI.check_result_index_bounds(m, attr)
    return MOI.get(m, attr, mosek_index(m, vi))
end

#### ConstraintBasisStatus

function _adjust_nonbasic(status, ::Type{S}) where {S}
    if status == MOI.NONBASIC_AT_LOWER
        return MOI.NONBASIC
    elseif status == MOI.NONBASIC_AT_UPPER
        return MOI.NONBASIC
    end
    return status
end

_adjust_nonbasic(status, ::Type{MOI.Interval{Float64}}) = status

function MOI.get(
    m::Optimizer,
    attr::MOI.ConstraintBasisStatus,
    ci::MOI.ConstraintIndex{MOI.ScalarAffineFunction{Float64},S},
) where {S}
    MOI.check_result_index_bounds(m, attr)
    subi = getindex(m.c_block, ci.value)
    status = m.solutions[attr.result_index].cstatus[subi]
    return _adjust_nonbasic(_basis_status_code(status, attr), S)
end

#### Constraint solution values

function MOI.get(
    m::Optimizer,
    attr::MOI.ConstraintPrimal,
    ci::MOI.ConstraintIndex{MOI.VariableIndex,D},
) where {D}
    MOI.check_result_index_bounds(m, attr)
    col = column(m, _variable(ci))
    return m.solutions[attr.result_index].xx[col.value]
end

# Semidefinite domain for a variable
function MOI.get!(
    output::Vector{Float64},
    m::Optimizer,
    attr::MOI.ConstraintPrimal,
    ci::MOI.ConstraintIndex{
        MOI.VectorOfVariables,
        MOI.PositiveSemidefiniteConeTriangle,
    },
)
    MOI.check_result_index_bounds(m, attr)
    whichsol = m.solutions[attr.result_index].whichsol
    return output[1:length(output)] = reorder(
        Mosek.getbarxj(m.task, whichsol, ci.value),
        MOI.PositiveSemidefiniteConeTriangle,
        false,
    )
end

# Any other domain for variable vector
function MOI.get!(
    output::Vector{Float64},
    m::Optimizer,
    attr::MOI.ConstraintPrimal,
    ci::MOI.ConstraintIndex{MOI.VectorOfVariables,D},
) where {D}
    MOI.check_result_index_bounds(m, attr)
    cols = columns(m, ci)
    output[1:length(output)] =
        reorder(m.solutions[attr.result_index].xx[cols.values], D, false)
    return
end

function MOI.get(
    m::Optimizer,
    attr::MOI.ConstraintPrimal,
    ci::MOI.ConstraintIndex{MOI.ScalarAffineFunction{Float64},D},
) where {D}
    MOI.check_result_index_bounds(m, attr)
    subi = getindex(m.c_block, ci.value)
    return m.solutions[attr.result_index].xc[subi]
end

function _variable_constraint_dual(
    sol::MosekSolution,
    col::ColumnIndex,
    ::Type{<:Union{MOI.Interval{Float64},MOI.EqualTo{Float64}}},
)
    return sol.slx[col.value] - sol.sux[col.value]
end

function _variable_constraint_dual(
    sol::MosekSolution,
    col::ColumnIndex,
    ::Type{MOI.GreaterThan{Float64}},
)
    return sol.slx[col.value]
end

function _variable_constraint_dual(
    sol::MosekSolution,
    col::ColumnIndex,
    ::Type{MOI.LessThan{Float64}},
)
    return -sol.sux[col.value]
end

function MOI.get(
    m::Optimizer,
    attr::MOI.ConstraintDual,
    ci::MOI.ConstraintIndex{MOI.VariableIndex,S},
) where {S<:ScalarLinearDomain}
    MOI.check_result_index_bounds(m, attr)
    col = column(m, _variable(ci))
    dual = _variable_constraint_dual(m.solutions[attr.result_index], col, S)
    return _dual_scale(m) * dual
end

function reorder(
    i::Integer,
    set::MOI.GeometricMeanCone,
    moi_to_mosek::Bool,
)
    if moi_to_mosek
       if i == 1
           MOI.dimension(set)
       else
           i - 1
       end
    else
        if i < MOI.dimension(set)
            i + 1
        else
            1
        end
    end
end

function reorder(x::AbstractVector, ::Type{MOI.GeometricMeanCone}, moi_to_mosek::Bool)
    if moi_to_mosek
        [x[2:length(x)]...,x[1]]
    else
        [x[length(x)],x[1:length(x)-1]...]
    end
end

# The dual or primal of an SDP variable block is returned in lower triangular
# form but the constraint is in upper triangular form.
function reorder(
    k::Integer,
    set::MOI.Scaled{MOI.PositiveSemidefiniteConeTriangle},
    moi_to_mosek::Bool,
)
    # `i` is the row in columnwise upper triangular form
    # the returned value is in columnwise lower triangular form
    if !moi_to_mosek
        # If we reverse things, the columnwise lower triangular becomes a
        # columnwise upper triangular so we can use `trimap`
        k = MOI.dimension(set) - k + 1
    end
    j = div(1 + isqrt(8k - 7), 2)
    i = k - div((j - 1) * j, 2)
    d = MOI.side_dimension(set)
    @assert 0 < j <= d
    @assert 0 < i <= j
    k = MOI.Utilities.trimap(d - j + 1, d - i + 1)
    if moi_to_mosek
        k = MOI.dimension(set) - k + 1
    end
    return k
end

function reorder(
    x::AbstractVector,
    ::Type{
        <:Union{
            MOI.Scaled{MOI.PositiveSemidefiniteConeTriangle},
            MOI.PositiveSemidefiniteConeTriangle,
        },
    },
    moi_to_mosek::Bool,
)
    n = MOI.Utilities.side_dimension_for_vectorized_dimension(length(x))
    @assert length(x) == MOI.dimension(MOI.PositiveSemidefiniteConeTriangle(n))
    y = similar(x)
    k = 0
    for j in 1:n, i in j:n
        k += 1
        o = div((i - 1) * i, 2) + j
        if moi_to_mosek
            y[k] = x[o]
        else
            y[o] = x[k]
        end
    end
    @assert k == length(x)
    return y
end

const ExpCones = Union{MOI.ExponentialCone,MOI.DualExponentialCone}

function reorder(i::Integer, ::ExpCones, ::Bool)
    return (3:-1:1)[i]
end


function reorder(x::AbstractVector, ::Union{ExpCones,Type{<:ExpCones}}, ::Bool)
    return [x[3], x[2], x[1]]
end

const NoReorder = Union{
    MOI.SecondOrderCone,
    MOI.RotatedSecondOrderCone,
    MOI.PowerCone,
    MOI.DualPowerCone,
}

reorder(x, ::Union{NoReorder,Type{<:NoReorder}}, ::Bool) = x

function _dual_scale(m::Optimizer)
    if Mosek.getobjsense(m.task) == Mosek.MSK_OBJECTIVE_SENSE_MINIMIZE
        return 1.0
    else
        return -1.0
    end
end

# Semidefinite domain for a variable
function MOI.get!(
    output::Vector{Float64},
    m::Optimizer,
    attr::MOI.ConstraintDual,
    ci::MOI.ConstraintIndex{
        MOI.VectorOfVariables,
        MOI.PositiveSemidefiniteConeTriangle,
    },
)
    MOI.check_result_index_bounds(m, attr)
    whichsol = m.solutions[attr.result_index].whichsol
    # It is in fact a real constraint and cid is the id of an ordinary constraint
    dual = reorder(
        Mosek.getbarsj(m.task, whichsol, ci.value),
        MOI.PositiveSemidefiniteConeTriangle,
        false,
    )
    output[1:length(output)] .= _dual_scale(m) .* dual
    return
end

# Any other domain for variable vector
function MOI.get!(
    output::Vector{Float64},
    m::Optimizer,
    attr::MOI.ConstraintDual,
    ci::MOI.ConstraintIndex{MOI.VectorOfVariables,D},
) where {D}
    MOI.check_result_index_bounds(m, attr)
    @assert ci.value > 0
    cols = columns(m, ci)
    idx = reorder(1:length(output), D, true)
    output[idx] =
        _dual_scale(m) * m.solutions[attr.result_index].snx[cols.values]
    return
end

function MOI.get!(
    output::Vector{Float64},
    m::Optimizer,
    attr::MOI.ConstraintDual,
    ci::MOI.ConstraintIndex{MOI.VectorAffineFunction{Float64},D},
) where {D}
    MOI.check_result_index_bounds(m, attr)
    afeidxs = Mosek.getaccafeidxlist(m.task, ci.value)
    idx = reorder(1:length(output), D, true)
    output[idx] = _dual_scale(m) * m.solutions[attr.result_index].doty[afeidxs]
    return
end

function MOI.get(
    m::Optimizer,
    attr::MOI.ConstraintDual,
    ci::MOI.ConstraintIndex{MOI.ScalarAffineFunction{Float64},D},
) where {D}
    MOI.check_result_index_bounds(m, attr)
    subi = getindex(m.c_block, ci.value)
    return _dual_scale(m) * m.solutions[attr.result_index].y[subi]
end

function solsize(m::Optimizer, ci::MOI.ConstraintIndex{MOI.VectorOfVariables})
    return Mosek.getconeinfo(m.task, cone_id(m, ci))[3]
end

function solsize(
    m::Optimizer,
    ci::MOI.ConstraintIndex{MOI.VectorAffineFunction{Float64}},
)
    return Mosek.getaccn(m.task, ci.value)
end

function solsize(
    m::Optimizer,
    ci::MOI.ConstraintIndex{
        MOI.VectorOfVariables,
        MOI.PositiveSemidefiniteConeTriangle,
    },
)
    d = m.sd_dim[ci.value]
    return MOI.dimension(MOI.PositiveSemidefiniteConeTriangle(d))
end

function MOI.get(
    m::Optimizer,
    attr::Union{MOI.ConstraintPrimal,MOI.ConstraintDual},
    ci::MOI.ConstraintIndex{<:MOI.AbstractVectorFunction},
)
    MOI.check_result_index_bounds(m, attr)
    output = Vector{Float64}(undef, solsize(m, ci))
    MOI.get!(output, m, attr, ci)
    return output
end

function MOI.get(
    m::Optimizer, # FIXME does Mosek provide this ?
    attr::MOI.ConstraintPrimal,
    ci::MOI.ConstraintIndex{MOI.VectorAffineFunction{Float64}},
)
    return MOI.Utilities.get_fallback(m, attr, ci)
end

#### Status codes

function MOI.get(m::Optimizer, attr::MOI.RawStatusString)
    if m.trm === nothing
        return "MOI.OPTIMIZE_NOT_CALLED"
    elseif m.trm == Mosek.MSK_RES_OK
        return join([Mosek.tostr(sol.solsta) for sol in m.solutions], ", ")
    else
        return Mosek.tostr(m.trm)
    end
end

# Mosek.jl defines `MosekEnum <: Integer` but it does not define
# `hash(::MosekEnum)`. This means creating a dictionary fails. Instead of fixing
# in Mosek.jl, or pirating a Base.hash(::Mosek.MosekEnum, ::UInt64) method here,
# we just use the `.value::Int32` field as the key.
const _TERMINATION_STATUS_MAP = Dict(
    Mosek.MSK_RES_TRM_MAX_ITERATIONS.value => MOI.ITERATION_LIMIT,
    Mosek.MSK_RES_TRM_MAX_TIME.value => MOI.TIME_LIMIT,
    Mosek.MSK_RES_TRM_OBJECTIVE_RANGE.value => MOI.OBJECTIVE_LIMIT,
    Mosek.MSK_RES_TRM_STALL.value => MOI.SLOW_PROGRESS,
    Mosek.MSK_RES_TRM_USER_CALLBACK.value => MOI.INTERRUPTED,
    Mosek.MSK_RES_TRM_MIO_NUM_RELAXS.value => MOI.OTHER_LIMIT,
    Mosek.MSK_RES_TRM_MIO_NUM_BRANCHES.value => MOI.NODE_LIMIT,
    Mosek.MSK_RES_TRM_NUM_MAX_NUM_INT_SOLUTIONS.value => MOI.SOLUTION_LIMIT,
    Mosek.MSK_RES_TRM_MAX_NUM_SETBACKS.value => MOI.OTHER_LIMIT,
    Mosek.MSK_RES_TRM_NUMERICAL_PROBLEM.value => MOI.SLOW_PROGRESS,
    Mosek.MSK_RES_TRM_LOST_RACE.value => MOI.OTHER_ERROR,
    Mosek.MSK_RES_TRM_INTERNAL.value => MOI.OTHER_ERROR,
    Mosek.MSK_RES_TRM_INTERNAL_STOP.value => MOI.OTHER_ERROR,
)

# Mosek.jl defines `MosekEnum <: Integer` but it does not define
# `hash(::MosekEnum)`. This means creating a dictionary fails. Instead of fixing
# in Mosek.jl, or pirating a Base.hash(::Mosek.MosekEnum, ::UInt64) method here,
# we just use the `.value::Int32` field as the key.
const _PROSTA_STATUS_MAP = Dict(
    Mosek.MSK_PRO_STA_UNKNOWN.value => MOI.OTHER_ERROR,
    Mosek.MSK_PRO_STA_PRIM_AND_DUAL_FEAS.value => MOI.LOCALLY_SOLVED,
    Mosek.MSK_PRO_STA_PRIM_FEAS.value => MOI.LOCALLY_SOLVED,
    # We proved only dual feasibility? What this one returns is up for debate.
    Mosek.MSK_PRO_STA_DUAL_FEAS.value => MOI.OTHER_ERROR,
    Mosek.MSK_PRO_STA_PRIM_INFEAS.value => MOI.INFEASIBLE,
    Mosek.MSK_PRO_STA_DUAL_INFEAS.value => MOI.DUAL_INFEASIBLE,
    Mosek.MSK_PRO_STA_PRIM_AND_DUAL_INFEAS.value => MOI.INFEASIBLE,
    Mosek.MSK_PRO_STA_ILL_POSED.value => MOI.OTHER_ERROR,
    Mosek.MSK_PRO_STA_PRIM_INFEAS_OR_UNBOUNDED.value =>
        MOI.INFEASIBLE_OR_UNBOUNDED,
)

function MOI.get(m::Optimizer, attr::MOI.TerminationStatus)
    if m.trm === nothing
        return MOI.OPTIMIZE_NOT_CALLED
    elseif m.trm == Mosek.MSK_RES_OK && length(m.solutions) > 0
        # The different solutions _could_ have different `.prosta`, but we just
        # return the information of the first one. This makes the most sense
        # because `result_index` defaults to 1, and we sort the solutions in
        # `MOI.optimize!` to ensure that the first solution is OPTIMAL, if one
        # exists.
        sol = first(m.solutions)
        if sol.solsta == Mosek.MSK_SOL_STA_OPTIMAL
            return MOI.OPTIMAL
        elseif sol.solsta == Mosek.MSK_SOL_STA_INTEGER_OPTIMAL
            return MOI.OPTIMAL
        end
        return _PROSTA_STATUS_MAP[sol.prosta.value]
    end
    return get(_TERMINATION_STATUS_MAP, m.trm.value, MOI.OTHER_ERROR)
end

# Mosek.jl defines `MosekEnum <: Integer` but it does not define
# `hash(::MosekEnum)`. This means creating a dictionary fails. Instead of fixing
# in Mosek.jl, or pirating a Base.hash(::Mosek.MosekEnum, ::UInt64) method here,
# we just use the `.value::Int32` field as the key.
const _PRIMAL_STATUS_MAP = Dict(
    Mosek.MSK_SOL_STA_UNKNOWN.value => MOI.UNKNOWN_RESULT_STATUS,
    Mosek.MSK_SOL_STA_OPTIMAL.value => MOI.FEASIBLE_POINT,
    Mosek.MSK_SOL_STA_PRIM_FEAS.value => MOI.FEASIBLE_POINT,
    Mosek.MSK_SOL_STA_DUAL_FEAS.value => MOI.UNKNOWN_RESULT_STATUS,
    Mosek.MSK_SOL_STA_PRIM_AND_DUAL_FEAS.value => MOI.FEASIBLE_POINT,
    Mosek.MSK_SOL_STA_PRIM_INFEAS_CER.value => MOI.NO_SOLUTION,
    Mosek.MSK_SOL_STA_DUAL_INFEAS_CER.value =>
        MOI.INFEASIBILITY_CERTIFICATE,
    Mosek.MSK_SOL_STA_PRIM_ILLPOSED_CER.value => MOI.NO_SOLUTION,
    Mosek.MSK_SOL_STA_DUAL_ILLPOSED_CER.value => MOI.REDUCTION_CERTIFICATE,
    Mosek.MSK_SOL_STA_INTEGER_OPTIMAL.value => MOI.FEASIBLE_POINT,
)

function MOI.get(m::Optimizer, attr::MOI.PrimalStatus)
    if !(1 <= attr.result_index <= MOI.get(m, MOI.ResultCount()))
        return MOI.NO_SOLUTION
    end
    solsta = m.solutions[attr.result_index].solsta
    return get(_PRIMAL_STATUS_MAP, solsta.value, MOI.UNKNOWN_RESULT_STATUS)
end

# Mosek.jl defines `MosekEnum <: Integer` but it does not define
# `hash(::MosekEnum)`. This means creating a dictionary fails. Instead of fixing
# in Mosek.jl, or pirating a Base.hash(::Mosek.MosekEnum, ::UInt64) method here,
# we just use the `.value::Int32` field as the key.
const _DUAL_STATUS_MAP = Dict(
    Mosek.MSK_SOL_STA_UNKNOWN.value => MOI.UNKNOWN_RESULT_STATUS,
    Mosek.MSK_SOL_STA_OPTIMAL.value => MOI.FEASIBLE_POINT,
    Mosek.MSK_SOL_STA_PRIM_FEAS.value => MOI.UNKNOWN_RESULT_STATUS,
    Mosek.MSK_SOL_STA_DUAL_FEAS.value => MOI.FEASIBLE_POINT,
    Mosek.MSK_SOL_STA_PRIM_AND_DUAL_FEAS.value => MOI.FEASIBLE_POINT,
    Mosek.MSK_SOL_STA_PRIM_INFEAS_CER.value =>
        MOI.INFEASIBILITY_CERTIFICATE,
    Mosek.MSK_SOL_STA_DUAL_INFEAS_CER.value => MOI.NO_SOLUTION,
    Mosek.MSK_SOL_STA_PRIM_ILLPOSED_CER.value => MOI.REDUCTION_CERTIFICATE,
    Mosek.MSK_SOL_STA_DUAL_ILLPOSED_CER.value => MOI.NO_SOLUTION,
    Mosek.MSK_SOL_STA_INTEGER_OPTIMAL.value => MOI.NO_SOLUTION,
)

function MOI.get(m::Optimizer, attr::MOI.DualStatus)
    if !(1 <= attr.result_index <= MOI.get(m, MOI.ResultCount()))
        return MOI.NO_SOLUTION
    end
    solsta = m.solutions[attr.result_index].solsta
    return get(_DUAL_STATUS_MAP, solsta.value, MOI.UNKNOWN_RESULT_STATUS)
end

function MOI.Utilities.substitute_variables(
    ::F,
    x::Mosek.MosekEnum,
) where {F<:Function}
    return x
end
