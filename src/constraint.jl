###############################################################################
# TASK ########################################################################
###### The `task` field should not be accessed outside this section. ##########

## Affine Constraints #########################################################
##################### lc ≤ Ax ≤ uc ############################################

function allocateconstraints(m::MosekModel, N::Int)
    numcon = getnumcon(m.task)
    alloced = ensurefree(m.c_block,N)
    id = newblock(m.c_block, N)

    M = numblocks(m.c_block) - length(m.c_block_slack)
    if alloced > 0
        appendcons(m.task, alloced)
        append!(m.c_constant, zeros(Float64,alloced))
    end
    if M > 0
        append!(m.c_block_slack, zeros(Float64,M))
        append!(m.c_coneid, zeros(Float64,M))
    end
    id
end

function getconboundlist(t::Mosek.Task, subj::Vector{Int32})
    n = length(subj)
    bk = Vector{Boundkey}(undef,n)
    bl = Vector{Float64}(undef,n)
    bu = Vector{Float64}(undef,n)
    for i in 1:n
        bki,bli,bui = getconbound(t,subj[i])
        bk[i] = bki
        bl[i] = bli
        bu[i] = bui
    end
    bk,bl,bu
end

# `putbaraij` and `putbarcj` need the whole matrix as a sum of sparse mat at once
function split_scalar_matrix(m::MosekModel, terms::Vector{MOI.ScalarAffineTerm{Float64}},
                             set_sd::Function)
    cols = Int32[]
    values = Float64[]
    sd_row  = Vector{Int32}[Int32[] for i in 1:length(m.sd_dim)]
    sd_col  = Vector{Int32}[Int32[] for i in 1:length(m.sd_dim)]
    sd_coef = Vector{Float64}[Float64[] for i in 1:length(m.sd_dim)]
	function add(col::ColumnIndex, coefficient::Float64)
		push!(cols, col.value)
		push!(values, coefficient)
	end
	function add(mat::MatrixIndex, coefficient::Float64)
        coef = mat.row == mat.column ? coefficient : coefficient / 2
        push!(sd_row[mat.matrix], mat.row)
        push!(sd_col[mat.matrix], mat.column)
        push!(sd_coef[mat.matrix], coef)
    end
	for term in terms
        add(mosek_index(m, term.variable_index), term.coefficient)
    end
    for j in 1:length(m.sd_dim)
        if !isempty(sd_row[j])
            id = appendsparsesymmat(m.task, m.sd_dim[j], sd_row[j],
                                    sd_col[j], sd_coef[j])
            set_sd(j, [id], [1.0])
        end
    end
    return cols, values
end

function set_row(task::Mosek.MSKtask, row::Int32, cols::ColumnIndices,
                 values::Vector{Float64})
    putarow(task, row, cols.values, values)
end
function set_row(m::MosekModel, row::Int32,
                 terms::Vector{MOI.ScalarAffineTerm{Float64}})
    cols, values = split_scalar_matrix(m, terms,
        (j, ids, coefs) -> putbaraij(m.task, row, j, ids, coefs))
    set_row(m.task, row, ColumnIndices(cols), values)
end


function set_coefficients(task::Mosek.MSKtask, rows::Vector{Int32},
                          cols::ColumnIndices, values::Vector{Float64})
    putaijlist(task, rows, cols.values, values)
end

function set_coefficients(task::Mosek.MSKtask, rows::Vector{Int32},
                          col::ColumnIndex, values::Vector{Float64})
    n = length(rows)
    @assert n == length(values)
    set_coefficient(task, rows, ColumnIndices(fill(col.value, n)), values)
end
function set_coefficients(m::MosekModel, rows::Vector{Int32},
                          vi::MOI.VariableIndex, values::Vector{Float64})
    set_coefficient(m.task, rows, mosek_index(m, vi), values)
end

function set_coefficient(task::Mosek.MSKtask, row::Int32, col::ColumnIndex,
                         value::Float64)
    putaij(task, row, col.value, value)
end
function set_coefficient(m::MosekModel, row::Int32, vi::MOI.VariableIndex,
                         value::Float64)
    set_coefficient(m.task, row, mosek_index(m, vi), value)
end

add_bound(m::MosekModel, rows::Vector{Int32}, constant::Vector{Float64}, dom::MOI.Reals)        = putconboundlist(m.task, rows, fill(MSK_BK_FR, MOI.dimension(dom)), -constant, -constant)
add_bound(m::MosekModel, rows::Vector{Int32}, constant::Vector{Float64}, dom::MOI.Zeros)        = putconboundlist(m.task, rows, fill(MSK_BK_FX, MOI.dimension(dom)), -constant, -constant)
add_bound(m::MosekModel, rows::Vector{Int32}, constant::Vector{Float64}, dom::MOI.Nonnegatives) = putconboundlist(m.task, rows, fill(MSK_BK_LO, MOI.dimension(dom)), -constant, -constant)
add_bound(m::MosekModel, rows::Vector{Int32}, constant::Vector{Float64}, dom::MOI.Nonpositives) = putconboundlist(m.task, rows, fill(MSK_BK_UP, MOI.dimension(dom)), -constant, -constant)
add_bound(m::MosekModel, row::Int32, constant::Float64, dom::MOI.GreaterThan{Float64}) = putconbound(m.task, row, MSK_BK_LO, dom.lower - constant, dom.lower - constant)
add_bound(m::MosekModel, row::Int32, constant::Float64, dom::MOI.LessThan{Float64})    = putconbound(m.task, row, MSK_BK_UP, dom.upper - constant, dom.upper - constant)
add_bound(m::MosekModel, row::Int32, constant::Float64, dom::MOI.EqualTo{Float64})     = putconbound(m.task, row, MSK_BK_FX, dom.value - constant, dom.value - constant)
add_bound(m::MosekModel, row::Int32, constant::Float64, dom::MOI.Interval{Float64})    = putconbound(m.task, row, MSK_BK_RA, dom.lower - constant, dom.upper - constant)

## Variable Constraints #######################################################
####################### lx ≤ x ≤ u ############################################
#######################      x ∈ K ############################################

function getvarboundlist(t::Mosek.Task, subj::Vector{Int32})
    n = length(subj)
    bk = Vector{Boundkey}(undef,n)
    bl = Vector{Float64}(undef,n)
    bu = Vector{Float64}(undef,n)
    for i in 1:n
        bki,bli,bui = getvarbound(t, subj[i])
        bk[i] = bki
        bl[i] = bli
        bu[i] = bui
    end
    bk,bl,bu
end


function add_variable_constraint(m::MosekModel, col::Int32, dom::MOI.Interval)
    putvarbound(m.task, col, MSK_BK_RA, dom.lower, dom.upper)
end
function add_variable_constraint(m::MosekModel, col::Int32, dom::MOI.EqualTo)
    putvarbound(m.task, col, MSK_BK_FX, dom.value, dom.value)
end
function add_variable_constraint(m::MosekModel, col::Int32, ::MOI.Integer)
    putvartype(m.task, col, MSK_VAR_TYPE_INT)
end
function add_variable_constraint(m::MosekModel, col::Int32, ::MOI.ZeroOne)
    putvartype(m.task, col, MSK_VAR_TYPE_INT)
    putvarbound(m.task, col, MSK_BK_RA, 0.0, 1.0)
end
function add_variable_constraint(m::MosekModel, col::Int32, dom::MOI.LessThan)
    bk, lo, up = getvarbound(m.task, col)
    bk = if (bk == MSK_BK_FR) MSK_BK_UP else MSK_BK_RA end
    putvarbound(m.task, Int32(col), bk, lo, dom.upper)
end
function add_variable_constraint(m::MosekModel, col::Int32,
                                 dom::MOI.GreaterThan)
    bk, lo, up = getvarbound(m.task, col)
    bk = if (bk == MSK_BK_FR) MSK_BK_LO else MSK_BK_RA end
    putvarbound(m.task, Int32(col), bk, dom.lower, up)
end

add_variable_constraint(::MosekModel, ::Vector{Int32}, ::MOI.Reals) = nothing
function add_variable_constraint(m::MosekModel, cols::Vector{Int32},
                                 dom::MOI.Zeros)
    n = length(cols)
    @assert n == MOI.dimension(dom)
    bnd = zeros(Float64, n)
    putvarboundlist(m.task, cols, fill(MSK_BK_FX, n), bnd, bnd)
end
function add_variable_constraint(m::MosekModel, cols::Vector{Int32},
                                 dom::MOI.Nonnegatives)
    n = length(cols)
    @assert n == MOI.dimension(dom)
    bkx = Vector{Boundkey}(undef, n)
    blx = zeros(Float64, n)
    bux = zeros(Float64, n)
    for (i, col) in enumerate(cols)
        bk, lo, up = getvarbound(m.task, col)
        bkx[i] = bk == MSK_BK_FR ? MSK_BK_LO : MSK_BK_RA
        bux[i] = up
    end
    putvarboundlist(m.task, cols, bkx, blx, bux)
end

function add_variable_constraint(m::MosekModel, cols::Vector{Int32},
                                 dom::MOI.Nonpositives)
    n = length(cols)
    @assert n == MOI.dimension(dom)
    bkx = Vector{Boundkey}(undef, n)
    blx = zeros(Float64, n)
    bux = zeros(Float64, n)
    for (i, col) in enumerate(cols)
        bk, lo, up = getvarbound(m.task, col)
        bkx[i] = bk == MSK_BK_FR ? MSK_BK_UP : MSK_BK_RA
        blx[i] = lo
    end
    putvarboundlist(m.task, cols, bkx, blx, bux)
end

cone_parameter(dom :: MOI.PowerCone{Float64})     = dom.exponent
cone_parameter(dom :: MOI.DualPowerCone{Float64}) = dom.exponent
cone_parameter(dom :: C) where C <: MOI.AbstractSet = 0.0

const VectorCone = Union{MOI.SecondOrderCone,
                         MOI.RotatedSecondOrderCone,
                         MOI.PowerCone,
                         MOI.DualPowerCone,
                         MOI.ExponentialCone,
                         MOI.DualExponentialCone}

function set_variable_domain(m::MosekModel, xcid::Int, cols::Vector{Int32},
                             dom::VectorCone)
    appendcone(m.task, cone_type(dom), cone_parameter(dom), cols)
    coneidx = getnumcone(m.task)
    m.conecounter += 1
    putconename(m.task,coneidx,"$(m.conecounter)")
    m.xc_coneid[xcid] = m.conecounter
end
function set_variable_domain(m::MosekModel, ::Int, cols::Vector{Int32},
                             dom::MOI.AbstractSet)
    add_variable_constraint(m, cols, dom)
end

## Name #######################################################################
###############################################################################

function set_row_name(task::Mosek.MSKtask, row::Int32, name::String)
    putconname(task, row, name)
end

function set_row_name(m::MosekModel,
                      c::MOI.ConstraintIndex{MOI.VectorAffineFunction{Float64}},
                      name::AbstractString) where {D}
    for row in rows(m, c)
        set_row_name(m.task, row, name)
    end
end
function set_row_name(m::MosekModel,
                      c::MOI.ConstraintIndex{MOI.ScalarAffineFunction{Float64}},
                      name::AbstractString)
    set_row_name(m.task, row(m, c), name)
end
function set_row_name(m::MosekModel, c::MOI.ConstraintIndex,
                      name::AbstractString)
    # Fallback for `SingleVariable` and `VectorOfVariables`.
    m.con_to_name[c] = name
end

function delete_name(m::MosekModel, ci::MOI.ConstraintIndex)
    name = MOI.get(m, MOI.ConstraintName(), ci)
    if !isempty(name)
        cis = m.constrnames[name]
        deleteat!(cis, findfirst(isequal(ci), cis))
    end
end

###############################################################################
# INDEXING ####################################################################
###############################################################################

function rows(m::MosekModel,
              c::MOI.ConstraintIndex{MOI.VectorAffineFunction{Float64}})::Vector{Int32} # TODO shouldn't need to convert
    return getindexes(m.c_block, ref2id(c))
end
function row(m::MosekModel,
             c::MOI.ConstraintIndex{MOI.ScalarAffineFunction{Float64}})::Int32
    return getindex(m.c_block, ref2id(c))
end

function allocatevarconstraints(m :: MosekModel,
                                N :: Int)
    nalloc = ensurefree(m.xc_block, N)
    id = newblock(m.xc_block, N)

    M = numblocks(m.xc_block) - length(m.xc_bounds)
    if M > 0
        append!(m.xc_bounds, zeros(Float64, M))
        append!(m.xc_coneid, zeros(Float64, M))
    end
    if nalloc > 0
        append!(m.xc_idxs, zeros(Float64, nalloc))
    end

    return id
end

###############################################################################
# MOI #########################################################################
###############################################################################

const PositiveSemidefiniteCone = MOI.PositiveSemidefiniteConeTriangle
const LinearFunction = Union{MOI.SingleVariable,
                             MOI.VectorOfVariables,
                             MOI.ScalarAffineFunction,
                             MOI.VectorAffineFunction}
const AffineFunction = Union{MOI.ScalarAffineFunction,
                             MOI.VectorAffineFunction}

const ScalarLinearDomain = Union{MOI.LessThan{Float64},
                                 MOI.GreaterThan{Float64},
                                 MOI.EqualTo{Float64},
                                 MOI.Interval{Float64}}
const VectorLinearDomain = Union{MOI.Nonpositives,
                                 MOI.Nonnegatives,
                                 MOI.Reals,
                                 MOI.Zeros}
const LinearDomain = Union{ScalarLinearDomain,VectorLinearDomain}
const ScalarIntegerDomain = Union{MOI.ZeroOne, MOI.Integer}

## Add ########################################################################
###############################################################################

MOI.supports_constraint(m::MosekModel, ::Type{<:Union{MOI.SingleVariable, MOI.ScalarAffineFunction}}, ::Type{<:ScalarLinearDomain}) = true
MOI.supports_constraint(m::MosekModel, ::Type{<:Union{MOI.VectorOfVariables, MOI.VectorAffineFunction}}, ::Type{<:VectorLinearDomain}) = true
MOI.supports_constraint(m::MosekModel, ::Type{MOI.VectorOfVariables}, ::Type{<:Union{VectorCone, MOI.PositiveSemidefiniteConeTriangle}}) = true
MOI.supports_constraint(m::MosekModel, ::Type{MOI.SingleVariable}, ::Type{<:ScalarIntegerDomain}) = true

## Affine Constraints #########################################################
##################### lc ≤ Ax ≤ uc ############################################

function MOI.add_constraint(m   :: MosekModel,
                            axb :: MOI.ScalarAffineFunction{Float64},
                            dom :: D) where {D <: MOI.AbstractScalarSet}

    # Duplicate indices not supported
    axb = MOIU.canonical(axb)

    N = 1
    conid = allocateconstraints(m, N)
    ci = MOI.ConstraintIndex{MOI.ScalarAffineFunction{Float64}, D}(UInt64(conid) << 1)
    r = row(m, ci)
    set_row(m, r, axb.terms)

    if length(m.c_constant) < length(m.c_block)
        append!(m.c_constant,
                zeros(Float64, length(m.c_block) - length(m.c_constant)))
    end
    m.c_constant[r] = axb.constant

    add_bound(m, r, axb.constant, dom)
    select(m.constrmap, MOI.ScalarAffineFunction{Float64}, D)[ci.value] = conid

    return ci
end

# TODO remove once ScalarizeBridge is done:
# https://github.com/JuliaOpt/MathOptInterface.jl/pull/664
function MOI.add_constraint(m   :: MosekModel,
                            axb :: MOI.VectorAffineFunction{Float64},
                            dom :: D) where { D <: VectorLinearDomain }

    # Duplicate indices not supported
    axb = MOIU.canonical(axb)

    N = MOI.dimension(dom)
    conid = allocateconstraints(m,N)
    ci = MOI.ConstraintIndex{MOI.VectorAffineFunction{Float64}, D}(UInt64(conid) << 1)
    r = rows(m, ci)
    fs = MOIU.eachscalar(axb)
    for i in 1:N
        set_row(m, r[i], fs[i].terms)
    end

    m.c_constant[r] .= axb.constants

    add_bound(m, r, axb.constants, dom)
    select(m.constrmap, MOI.VectorAffineFunction{Float64}, D)[ci.value] = conid

    return ci
end

## Variable Constraints #######################################################
####################### lx ≤ x ≤ u ############################################
#######################      x ∈ K ############################################

# We allow following. Each variable can have
# - at most most upper and one lower bound
# - belong to at most one non-semidefinite cone
# - any number of semidefinite cones, which are implemented as ordinary constraints
# This is when things get a bit funky; By default a variable has no
# bounds, i.e. "free". Adding a `GreaterThan` or `Nonnegatives`
# constraint causes it to have a defined lower bound but no upper
# bound, allowing a `LessThan` or ``Nonpositives` constraint to be
# added later. Adding a `Interval` constraint defines both upper and
# lower bounds. Adding a `Reals` constraint will effectively be the
# same as an interval ]-infty;infty[, in that it will define both
# upper and lower bounds, and not allow those to be set afterwards.

domain_type_mask(dom :: MOI.Reals)        = (boundflag_lower | boundflag_upper)
domain_type_mask(dom :: MOI.Interval)     = (boundflag_lower | boundflag_upper)
domain_type_mask(dom :: MOI.EqualTo)      = (boundflag_lower | boundflag_upper)
domain_type_mask(dom :: MOI.Zeros)        = (boundflag_lower | boundflag_upper)
domain_type_mask(dom :: MOI.GreaterThan)  = boundflag_lower
domain_type_mask(dom :: MOI.Nonnegatives) = boundflag_lower
domain_type_mask(dom :: MOI.LessThan)     = boundflag_upper
domain_type_mask(dom :: MOI.Nonpositives) = boundflag_upper

domain_type_mask(dom :: MOI.SecondOrderCone)        = boundflag_cone
domain_type_mask(dom :: MOI.RotatedSecondOrderCone) = boundflag_cone
domain_type_mask(dom :: MOI.ExponentialCone)        = boundflag_cone
domain_type_mask(dom :: MOI.PowerCone)              = boundflag_cone
domain_type_mask(dom :: MOI.DualExponentialCone)    = boundflag_cone
domain_type_mask(dom :: MOI.DualPowerCone)          = boundflag_cone

domain_type_mask(dom :: MOI.PositiveSemidefiniteConeTriangle) = 0

domain_type_mask(dom :: MOI.Integer) = boundflag_int
domain_type_mask(dom :: MOI.ZeroOne) = (boundflag_int | boundflag_upper | boundflag_lower)

cone_type(::MOI.ExponentialCone)        = MSK_CT_PEXP
cone_type(::MOI.DualExponentialCone)    = MSK_CT_DEXP
cone_type(::MOI.PowerCone)              = MSK_CT_PPOW
cone_type(::MOI.DualPowerCone)          = MSK_CT_DPOW
cone_type(::MOI.SecondOrderCone)        = MSK_CT_QUAD
cone_type(::MOI.RotatedSecondOrderCone) = MSK_CT_RQUAD

function MOI.add_constraint(
    m   :: MosekModel,
    xs  :: MOI.SingleVariable,
    dom :: D) where {D <: MOI.AbstractScalarSet}

    msk_idx = mosek_index(m, xs.variable)
    if !(msk_idx isa ColumnIndex)
        error("Cannot add $D constraint on a matrix variable")
    end
    col = msk_idx.value

    mask = domain_type_mask(dom)
    if mask & m.x_boundflags[col] != 0
        error("Cannot put multiple bound sets of the same type on a variable")
    end

    xcid = allocatevarconstraints(m, 1)

    xc_sub = getindex(m.xc_block, xcid)

    m.xc_bounds[xcid]  = mask
    m.xc_idxs[xc_sub] = col

    add_variable_constraint(m, col, dom)

    m.x_boundflags[col] |= mask

    conref = MOI.ConstraintIndex{MOI.SingleVariable,D}(UInt64(xcid) << 1)

    select(m.constrmap,MOI.SingleVariable,D)[conref.value] = xcid
    conref
end

function MOI.add_constraint(m::MosekModel, xs::MOI.VectorOfVariables,
                            dom::D) where {D <: MOI.AbstractVectorSet}
    if any(vi -> is_matrix(m, vi), xs.variables)
        error("Cannot add $D constraint on a matrix variable")
    end
    cols = reorder(columns(m, xs.variables).values, D)

    mask = domain_type_mask(dom)
    if any(mask .& m.x_boundflags[cols] .> 0)
        error("Cannot multiple bound sets of the same type to a variable")
    end

    N = MOI.dimension(dom)
    xcid = allocatevarconstraints(m, N)
    xc_sub = getindexes(m.xc_block, xcid)

    m.xc_bounds[xcid] = mask
    m.xc_idxs[xc_sub] = cols

    set_variable_domain(m, xcid, cols, dom)

    m.x_boundflags[cols] .|= mask

    conref = MOI.ConstraintIndex{MOI.VectorOfVariables, D}(UInt64(xcid) << 1)
    select(m.constrmap,MOI.VectorOfVariables, D)[conref.value] = xcid
    return conref
end

################################################################################
################################################################################

function MOI.add_constraint(m  ::MosekModel,
                            xs ::MOI.VectorOfVariables,
                            dom::MOI.PositiveSemidefiniteConeTriangle)
    N = dom.side_dimension
    if N < 2
        error("Invalid dimension for semidefinite constraint, got $N which is ",
              "smaller than the minimum dimension 2.")
    end
    appendbarvars(m.task, [Int32(N)])
    push!(m.sd_dim, N)
    id = length(m.sd_dim)
    sd_row  = Dict{Int, Vector{Int32}}()
    sd_col  = Dict{Int, Vector{Int32}}()
    sd_coef = Dict{Int, Vector{Float64}}()
    k = 0
    for i in 1:N
        for j in 1:i
            k += 1
            vi = xs.variables[k]
            m.x_sd[vi.value] = MatrixIndex(id, i, j)

            if variable_type(m, vi) == MatrixVariable
                error("Variable $vi cannot be part of two matrix variables.")
            elseif variable_type(m, vi) == ScalarVariable
                # The variable has already been used, we need replace the
                # coefficients in the `A` matrix by matrix coefficients
                nnz, rows, vals = getacol(m.task, column(m, vi).value)
                @assert nnz == length(rows) == length(vals)
                for ii in 1:nnz
                    if !haskey(sd_row, rows[ii])
                        sd_row[rows[ii]] = Int32[]
                        sd_col[rows[ii]] = Int32[]
                        sd_coef[rows[ii]] = Float64[]
                    end
                    push!(sd_row[rows[ii]], i)
                    push!(sd_col[rows[ii]], j)
                    push!(sd_coef[rows[ii]], i == j ? vals[ii] : vals[ii] / 2)
                end
                # TODO objective
                MOI.delete(m, vi)
            end
            m.x_type[vi.value] = MatrixVariable
        end
    end
    for row in eachindex(sd_row)
        sid = appendsparsesymmat(m.task, N, sd_row[row], sd_col[row],
                                sd_coef[row])
        putbaraij(m.task, row, id, [sid], [1.0])
    end
    @assert k == length(xs.variables)


    conref = MOI.ConstraintIndex{MOI.VectorOfVariables, MOI.PositiveSemidefiniteConeTriangle}(id)
    select(m.constrmap, MOI.VectorOfVariables, MOI.PositiveSemidefiniteConeTriangle)[conref.value] = id

    return conref
end

## Modify #####################################################################
###############################################################################

### SET
chgbound(bl::Float64,bu::Float64,k::Float64,dom :: MOI.LessThan{Float64})    = bl,dom.upper-k
chgbound(bl::Float64,bu::Float64,k::Float64,dom :: MOI.GreaterThan{Float64}) = dom.lower-k,bu
chgbound(bl::Float64,bu::Float64,k::Float64,dom :: MOI.EqualTo{Float64})     = dom.value-k,dom.value-k
chgbound(bl::Float64,bu::Float64,k::Float64,dom :: MOI.Interval{Float64})    = dom.lower-k,dom.upper-k

function MOI.set(m::MosekModel,
                 ::MOI.ConstraintSet,
                 xcref::MOI.ConstraintIndex{F,D},
                 dom::D) where { F    <: MOI.SingleVariable,
                                 D    <: ScalarLinearDomain }
    xcid = ref2id(xcref)
    col = m.xc_idxs[getindex(m.xc_block, xcid)]
    bk, bl, bu = getvarbound(m.task, col)
    bl, bu = chgbound(bl, bu, 0.0, dom)
    putvarbound(m.task, col, bk, bl, bu)
end


function MOI.set(m::MosekModel,
                 ::MOI.ConstraintSet,
                 cref::MOI.ConstraintIndex{F,D},
                 dom::D) where { F    <: MOI.ScalarAffineFunction,
                                 D    <: ScalarLinearDomain }
    cid = ref2id(cref)
    i = getindex(m.c_block,cid) # since we are in a scalar domain
    bk,bl,bu = getconbound(m.task,i)
    bl,bu = chgbound(bl,bu,0.0,dom)
    putconbound(m.task,i,bk,bl,bu)
end


### MODIFY
function MOI.modify(m   ::MosekModel,
                    c   ::MOI.ConstraintIndex{MOI.ScalarAffineFunction{Float64},D},
                    func::MOI.ScalarConstantChange{Float64}) where {D <: MOI.AbstractSet}

    cid = ref2id(c)

    i = getindex(m.c_block, cid)
    bk,bl,bu = getconbound(m.task,i)
    bl += m.c_constant[i] - func.new_constant
    bu += m.c_constant[i] - func.new_constant
    m.c_constant[i] = func.new_constant
    putconbound(m.task,i,bk,bl,bu)
end

function MOI.modify(m   ::MosekModel,
                    c   ::MOI.ConstraintIndex{MOI.ScalarAffineFunction{Float64}},
                    func::MOI.ScalarCoefficientChange{Float64})
    set_coefficient(m, row(m, c), func.variable, func.new_coefficient)
end

function MOI.modify(m::MosekModel,
                    c::MOI.ConstraintIndex{MOI.VectorAffineFunction{Float64}},
                    func::MOI.VectorConstantChange{Float64})
    cid = ref2id(c)
    @assert(cid > 0)

    subi = getindexes(m.c_block, cid)
    bk = Vector{Int32}(undef,length(subi))
    bl = Vector{Float64}(undef,length(subi))
    bu = Vector{Float64}(undef,length(subi))

    bk,bl,bu = getconboundlist(m.task,convert(Vector{Int32},subi))
    bl += m.c_constant[subi] - func.new_constant
    bu += m.c_constant[subi] - func.new_constant
    m.c_constant[subi] = func.new_constant

    putconboundlist(m.task, convert(Vector{Int32}, subi), bk, bl, bu)
end

function MOI.modify(m::MosekModel,
                    c::MOI.ConstraintIndex{MOI.VectorAffineFunction{Float64}},
                    func::MOI.MultirowChange{Float64})
    @assert ref2id(c) > 0
    set_coefficients(m, rows(m, c)[getindex.(func.new_coefficients, 1)],
                     func.variable, getindex.(func.new_coefficients, 2))
end

### TRANSFORM
function MOI.transform(m::MosekModel,
                       cref::MOI.ConstraintIndex{F,D},
                       newdom::D) where {F <: MOI.AbstractFunction,
                                         D <: MOI.AbstractSet}
    MOI.modify(m,cref,newdom)
    cref
end

function MOI.transform(m::MosekModel,
                       cref::MOI.ConstraintIndex{MOI.ScalarAffineFunction{Float64},D1},
                       newdom::D2) where {D1 <: ScalarLinearDomain,
                                          D2 <: ScalarLinearDomain}
    F = MOI.ScalarAffineFunction{Float64}

    cid = ref2id(cref)

    r = row(m, cref)
    add_bound(m, r, m.c_constant[r], newdom)

    newcref = MOI.ConstraintIndex{F,D2}(UInt64(cid) << 1)
    delete!(select(m.constrmap,F,D1), cref.value)
    select(m.constrmap, F, D2)[newcref.value] = cid
    newcref
end

function MOI.transform(m::MosekModel,
                       cref::MOI.ConstraintIndex{MOI.VectorAffineFunction{Float64},D1},
                       newdom::D2) where {D1 <: VectorLinearDomain,
                                          D2 <: VectorLinearDomain}
    F = MOI.VectorAffineFunction{Float64}

    cid = ref2id(cref)

    r = rows(m, cref)

    add_bound(m, r, m.c_constant[r], newdom)

    newcref = MOI.ConstraintIndex{F,D2}(UInt64(cid) << 1)
    delete!(select(m.constrmap,F,D1), cref.value)
    select(m.constrmap,F,D2)[newcref.value] = cid
    newcref
end

## Delete #####################################################################
###############################################################################

function MOI.is_valid(model::MosekModel,
                      ref::MOI.ConstraintIndex{F, D}) where {F, D}
    return haskey(select(model.constrmap, F, D), ref.value)
end

function MOI.delete(
    m::MosekModel,
    cref::MOI.ConstraintIndex{F,D}) where {F <: AffineFunction,
                                           D <: Union{ScalarLinearDomain,
                                                      VectorLinearDomain}}
    if !MOI.is_valid(m, cref)
        throw(MOI.InvalidIndex(cref))
    end

    delete_name(m, cref)

    delete!(select(m.constrmap, F, D), cref.value)

    cid = ref2id(cref)
    subi = getindexes(m.c_block,cid)

    n = length(subi)
    subi_i32 = convert(Vector{Int32},subi)
    ptr = fill(Int64(0),n)
    putarowlist(m.task,subi_i32,ptr,ptr,Int32[],Float64[])
    b = fill(0.0,n)
    putconboundlist(m.task,subi_i32,fill(MSK_BK_FX,n),b,b)

    m.c_constant[subi] .= 0.0
    deleteblock(m.c_block,cid)
end

function MOI.delete(
    m::MosekModel,
    cref::MOI.ConstraintIndex{F,D}) where {F <: Union{MOI.SingleVariable,
                                                      MOI.VectorOfVariables},
                                           D <: Union{ScalarLinearDomain,
                                                      VectorLinearDomain,
                                                      ScalarIntegerDomain}}
    if !MOI.is_valid(m, cref)
        throw(MOI.InvalidIndex(cref))
    end

    delete_name(m, cref)

    delete!(select(m.constrmap, F, D), cref.value)

    xcid = ref2id(cref)
    sub = getindexes(m.xc_block,xcid)

    subj = [ getindex(m.x_block,i) for i in sub ]
    N = length(subj)

    m.x_boundflags[subj] .&= ~m.xc_bounds[xcid]
    if m.xc_bounds[xcid] & boundflag_int != 0
        for i in 1:length(subj)
            putvartype(m.task,subj[i],MSK_VAR_TYPE_CONT)
        end
    end

    if m.xc_bounds[xcid] & boundflag_lower != 0 && m.xc_bounds[xcid] & boundflag_upper != 0
        bnd = fill(0.0, length(N))
        putvarboundlist(m.task,convert(Vector{Int32},subj),fill(MSK_BK_FR,N),bnd,bnd)
    elseif m.xc_bounds[xcid] & boundflag_lower != 0
        bnd = fill(0.0, length(N))
        bk,bl,bu = getvarboundlist(m.task, convert(Vector{Int32},subj))

        for i in 1:N
            if MSK_BK_RA == bk[i] || MSK_BK_FX == bk[i]
                bk[i] = MSK_BK_UP
            else
                bk[i] = MSK_BK_FR
            end
        end

        putvarboundlist(m.task,convert(Vector{Int32},subj),bk,bl,bu)
    elseif m.xc_bounds[xcid] & boundflag_upper != 0
        bnd = fill(0.0, length(N))
        bk,bl,bu = getvarboundlist(m.task, subj)

        for i in 1:N
            if MSK_BK_RA == bk[i] || MSK_BK_FX == bk[i]
                bk[i] = MSK_BK_LO
            else
                bk[i] = MSK_BK_FR
            end
        end

        putvarboundlist(m.task,convert(Vector{Int32},subj),bk,bl,bu)
    else
        @assert(false)
        # should not happen
    end

    m.x_numxc[subj] .-= 1
    m.xc_idxs[sub] .= 0
    m.xc_bounds[xcid] = 0

    deleteblock(m.xc_block, xcid)
end

## List #######################################################################
###############################################################################

## Name #######################################################################
###############################################################################
function MOI.supports(::MosekModel, ::MOI.ConstraintName,
                      ::Type{<:MOI.ConstraintIndex})
    return true
end
function MOI.set(m::MosekModel, ::MOI.ConstraintName, ci::MOI.ConstraintIndex,
                 name ::AbstractString)
    delete_name(m, ci)
    if !haskey(m.constrnames, name)
        m.constrnames[name] = MOI.ConstraintIndex[]
    end
    push!(m.constrnames[name], ci)
    set_row_name(m, ci, name)
end
function MOI.get(m::MosekModel, ::MOI.ConstraintName,
                 ci::MOI.ConstraintIndex{<:Union{MOI.ScalarAffineFunction{Float64},
                                                 MOI.VectorAffineFunction{Float64}}})
    # All rows should have same name so we take the first one
    return getconname(m.task, getindexes(m.c_block, ref2id(ci))[1])
end
function MOI.get(m::MosekModel, ::MOI.ConstraintName, ci::MOI.ConstraintIndex)
    return get(m.con_to_name, ci, "")
end
function MOI.get(m::MosekModel, CI::Type{<:MOI.ConstraintIndex}, name::String)
    #asgn, row = getconnameindex(m.task, name)
    #if iszero(asgn)
    #    return nothing
    #else
    #    # TODO how to recover function and constraint type ?
    #end
    if !haskey(m.constrnames, name)
        return nothing
    end
    cis = m.constrnames[name]
    if isempty(cis)
        return nothing
    end
    if !isone(length(cis))
        error("Multiple constraints have the name $name.")
    end
    ci = first(cis)
    if !(ci isa CI)
        return nothing
    end
    return ci
end
