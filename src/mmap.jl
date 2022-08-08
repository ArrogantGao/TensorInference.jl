# MMAP : computing the most likely assignment to the query variables,  Xₘ ⊆ X after marginalizing out the remaining variables Xₛ = X \ Xₘ.

# A cluster is the elimination of a subset of variables.
struct Cluster{LT}
    eliminated_vars::Vector{LT}
    code::AbstractEinsum
    tensors::Vector
end

"""
$(TYPEDEF)

Computing the most likely assignment to the query variables,  Xₘ ⊆ X after marginalizing out the remaining variables Xₛ = X \\ Xₘ.

```math
{\\rm MMAP}(X_i|E=e) = \\arg \\max_{X_M} \\sum_{X_S} \\prod_{F} f(x_M, x_S, e)
```

### Fields
* `vars` is the remaining (or not marginalized) degree of freedoms in the tensor network.
* `code` is the tropical tensor network contraction pattern.
* `tensors` is the tensors fed into the tensor network.
* `clusters` is the clusters, each element of this cluster is a [`TensorNetworkModeling`](@ref) instance for marginalizing certain variables.
* `fixedvertices` is a dictionary to specifiy degree of freedoms fixed to certain values, which should not have overlap with the marginalized variables.
"""
struct MMAPModeling{LT,AT<:AbstractArray}
    vars::Vector{LT}
    code::AbstractEinsum
    tensors::Vector{AT}
    clusters::Vector{Cluster{LT}}
    fixedvertices::Dict{LT,Int}
end

function Base.show(io::IO, mmap::MMAPModeling)
    open = getiyv(mmap.code)
    variables = join([string_var(var, open, mmap.fixedvertices) for var in mmap.vars], ", ")
    tc, sc, rw = timespacereadwrite_complexity(mmap)
    println(io, "$(typeof(mmap))")
    println(io, "variables: $variables")
    println(io, "marginalized variables: $(map(x->x.eliminated_vars, mmap.clusters))")
    print_tcscrw(io, tc, sc, rw)
end
Base.show(io::IO, ::MIME"text/plain", mmap::MMAPModeling) = Base.show(io, mmap)

"""
$(TYPEDSIGNATURES)
"""
get_vars(mmap::MMAPModeling) = mmap.vars

"""
$(TYPEDSIGNATURES)
"""
function get_cards(mmap::MMAPModeling; fixedisone=false)
    vars = get_vars(mmap)
    [fixedisone && haskey(mmap.fixedvertices, vars[k]) ? 1 : length(mmap.tensors[k]) for k=1:length(vars)]
end

"""
$(TYPEDSIGNATURES)
"""
function MMAPModeling(instance::UAIInstance; marginalizedvertices, openvertices=(), optimizer=GreedyMethod(), simplifier=nothing)::MMAPModeling
    return MMAPModeling(1:instance.nvars, instance.factors; marginalizedvertices, fixedvertices=Dict(zip(instance.obsvars, instance.obsvals .- 1)), optimizer, simplifier, openvertices)
end

"""
$(TYPEDSIGNATURES)
"""
function MMAPModeling(vars::AbstractVector{LT}, factors::Vector{<:Factor{T}}; marginalizedvertices, openvertices=(),
            fixedvertices=Dict{LT,Int}(),
            optimizer=GreedyMethod(), simplifier=nothing,
            marginalize_optimizer=GreedyMethod(), marginalize_simplifier=nothing
        )::MMAPModeling where {T,LT}
    all_ixs = [[[var] for var in vars]..., [[factor.vars...] for factor in factors]...]  # labels for vertex tensors (unity tensors) and edge tensors
    iy = collect(LT, openvertices)
    if !isempty(setdiff(iy, vars))
        error("Marginalized variables should not contain any output variable.")
    end
    all_tensors = [[ones(T, 2) for _=1:length(vars)]..., getfield.(factors, :vals)...]
    size_dict = OMEinsum.get_size_dict(all_ixs, all_tensors)

    # detect clusters for marginalize variables
    subsets = connected_clusters(all_ixs, marginalizedvertices)
    clusters = Cluster{LT}[]
    ixs = Vector{LT}[]
    for (contracted, cluster) in subsets
        ts = all_tensors[cluster]
        ixsi = all_ixs[cluster]
        vari = unique!(vcat(ixsi...))
        iyi = setdiff(vari, contracted)
        codei = optimize_code(EinCode(ixsi, iyi), size_dict, marginalize_optimizer, marginalize_simplifier)
        push!(ixs, iyi)
        push!(clusters, Cluster(contracted, codei, ts))
    end
    rem_indices = setdiff(1:length(all_ixs), vcat([c.second for c in subsets]...))
    remaining_tensors = all_tensors[rem_indices]
    code = optimize_code(EinCode([all_ixs[rem_indices]..., ixs...], iy), size_dict, optimizer, simplifier)
    return MMAPModeling(setdiff(vars, marginalizedvertices), code, remaining_tensors, clusters, fixedvertices)
end

function OMEinsum.timespacereadwrite_complexity(mmap::MMAPModeling{LT}) where LT
    # extract size
    size_dict = Dict(zip(get_vars(mmap), get_cards(mmap; fixedisone=true)))
    sc = -Inf
    tcs = Float64[]
    rws = Float64[]
    for cluster in mmap.clusters
        # update variable sizes
        for k in 1:length(cluster.eliminated_vars)
            # the head sector are for unity tensors.
            size_dict[cluster.eliminated_vars[k]] = length(cluster.tensors[k])
        end
        tc, sci, rw = timespacereadwrite_complexity(cluster.code, size_dict)
        push!(tcs, tc)
        push!(rws, rw)
        sc = max(sc, sci)
    end

    tc, sci, rw = timespacereadwrite_complexity(mmap.code, size_dict)
    push!(tcs, tc)
    push!(rws, tc)
    OMEinsum.OMEinsumContractionOrders.log2sumexp2(tcs), max(sc, sci), OMEinsum.OMEinsumContractionOrders.log2sumexp2(rws)
end
OMEinsum.timespace_complexity(mmap::MMAPModeling) = timespacereadwrite_complexity(mmap)[1:2]

generate_tensors(mmap::MMAPModeling; usecuda) = [generate_tensors(mmap.code, mmap.tensors, mmap.fixedvertices; usecuda)..., map(cluster->probability(cluster; fixedvertices=mmap.fixedvertices, usecuda), mmap.clusters)...]

# find connected clusters
function connected_clusters(ixs, vars::Vector{LT}) where LT
    visited_ixs = falses(length(ixs))
    visited_vars = falses(length(vars))
    clusters = Pair{Vector{LT}, Vector{Int}}[]
    for (kv, var) in enumerate(vars)
        visited_vars[kv] && continue
        visited_vars[kv] = true
        cluster = LT[]=>Int[]
        visit_var!(var, vars, ixs, visited_ixs, visited_vars, cluster)
        sort!(cluster.second)  # sort the tensor indices
        if !isempty(cluster)
            push!(clusters, cluster)
        end
    end
    return clusters
end

function visit_var!(var, vars::AbstractVector{LT}, ixs, visited_ixs, visited_vars, cluster::Pair) where LT
    push!(cluster.first, var)
    # add all tensors have not been visited and contain var.
    included_vars = LT[]
    for (kx, ix) in enumerate(ixs)
        if !visited_ixs[kx] && var ∈ ix
            visited_ixs[kx] = true
            push!(cluster.second, kx)

            # new included vars
            for l in ix
                if l != var && l ∈ vars
                    kv = findfirst(==(l), vars)
                    if !visited_vars[kv]
                        visited_vars[kv] = true
                        push!(included_vars, l)
                    end
                end
            end
        end
    end
    # recurse over new variables
    for nvar in included_vars
        visit_var!(nvar, vars, ixs, visited_ixs, visited_vars, cluster)
    end
end

"""
$(TYPEDSIGNATURES)
"""
function most_probable_config(mmap::MMAPModeling; usecuda=false)::Tuple{Tropical,Vector}
    vars = get_vars(mmap)
    tensors = map(t->OMEinsum.asarray(Tropical.(log.(t)), t), generate_tensors(mmap; usecuda))
    logp, grads = cost_and_gradient(mmap.code, tensors)
    # use Array to convert CuArray to CPU arrays
    return Array(logp)[], map(k->haskey(mmap.fixedvertices, vars[k]) ? mmap.fixedvertices[vars[k]] : argmax(grads[k]) - 1, 1:length(vars))
end

"""
$(TYPEDSIGNATURES)
"""
function maximum_logp(mmap::MMAPModeling; usecuda=false)::AbstractArray{<:Tropical}
    tensors = map(t->OMEinsum.asarray(Tropical.(log.(t)), t), generate_tensors(mmap; usecuda))
    return mmap.code(tensors...)
end

"""
$(TYPEDSIGNATURES)
"""
function probability(mmap::MMAPModeling, config)::Real
    fixedvertices = merge(mmap.fixedvertices, Dict(zip(get_vars(mmap), config)))
    assign = Dict(zip(get_vars(mmap), config .+ 1))
    m1 = mapreduce(x->x[2][getindex.(Ref(assign), x[1])...], *, zip(getixsv(mmap.code), mmap.tensors))
    m2 = prod(cluster->probability(cluster; fixedvertices, usecuda=false)[], mmap.clusters)
    return m1 * m2
end

function probability(c::Cluster; fixedvertices, usecuda)::AbstractArray
    tensors = generate_tensors(c.code, c.tensors, fixedvertices; usecuda)
    return c.code(tensors...)
end