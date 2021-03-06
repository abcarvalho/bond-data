# vim: set fdm=marker :

module StatsMod

using CSV
using DataFrames
using Dates
using Statistics
using Distributed
using Latexify
using Printf

# STATS  {{{1
# Trace Stats (Bond Count, Trade Count, Trade Volume) {{{2
function stats_calculator(df::DataFrame, groups::Array{Symbol,1};
                          var_suffix::Symbol=Symbol(""))
    cols = vcat(groups, [:cusip_id, :entrd_vol_qt])
    gd = groupby(df[:, cols],  groups)
    cdf = combine(gd, :entrd_vol_qt =>  (x -> Statistics.quantile!(x, .25)) => :qt25_trd_vol,
                      :entrd_vol_qt => mean => :mean_trd_vol,
                      :entrd_vol_qt => median => :median_trd_vol,
                      :entrd_vol_qt => (x -> Statistics.quantile!(x, .75)) => :qt75_trd_vol,
                      :entrd_vol_qt => (x -> sum(x)/ 10^9) => :total_vol_tr,
                      nrow => :trd_count, :cusip_id => (x -> size(unique(x), 1)) => :cusips)

    if !isempty(string(var_suffix))
        col_names = [(x in groups) ? x : Symbol(x, var_suffix) for x in Symbol.(names(cdf))]
        rename!(cdf, col_names)
    end

    return cdf
end

function trace_stats(df::DataFrame)
    df[!, :ats_ind] = df[:, :ats_indicator] .!== missing
    groups = [:trd_exctn_yr, :trd_exctn_mo, :ats_ind, :ig]
    cols = vcat(groups, [:cusip_id, :entrd_vol_qt])

    # BY SECONDARY MARKET & RATING
    # Create stats by year/month/ats/ig indicator
    cdf = @time stats_calculator(df, groups)

    # By SECONDARY MARKET
    # Create stats by year/month/ats indicator
    g1 = [x for x in groups if x != :ig]
    tmp = stats_calculator(df, g1; var_suffix=:_sm)
    cdf = leftjoin(cdf, tmp, on = g1)
    cdf[!, :total_vol_perc_sm] = (cdf[!, :total_vol_tr] ./ cdf[!, :total_vol_tr_sm]) .* 100
    cdf[!, :trd_count_perc_sm] = (cdf[!, :trd_count] ./ cdf[!, :trd_count_sm]) .* 100

    # Create stats by year/month
    tmp = combine(groupby(cdf, [:trd_exctn_yr, :trd_exctn_mo]),
                  :total_vol_tr => sum => :total_vol_all,
                  :trd_count => sum => :trd_count_all)
    cdf = leftjoin(cdf, tmp, on = [:trd_exctn_yr, :trd_exctn_mo])
    cdf[!, :total_vol_perc] = (cdf[!, :total_vol_tr] ./ cdf[!, :total_vol_all]) .* 100
    cdf[!, :trd_count_perc] = (cdf[!, :trd_count] ./ cdf[!, :trd_count_all]) .* 100

    # Sort rows and reorder columns
    trd_cols = [:trd_count, :trd_count_perc,
                :trd_count_sm, :trd_count_perc_sm]
    vol_cols = [:total_vol_tr, :total_vol_perc,
                :total_vol_tr_sm, :total_vol_perc_sm]
    g2cols = [:qt25_trd_vol, :mean_trd_vol, :median_trd_vol, :qt75_trd_vol]
    g1cols = [Symbol(x, :_sm) for x in g2cols]
    col_order=vcat(groups, [:cusips, :cusips_sm],
                   trd_cols, vol_cols,
                   g2cols, g1cols)

    return sort!(cdf[:, col_order], groups)
end
# }}}2
# INDICATORS {{{2
function convert_2_bool(df::DataFrame, x)
    return .&(df[:, x] .!== missing, df[:, x] .== "Y")
end
# }}}2
# CUSIPS stats by ATS/OTC and IG/HY {{{2
function smk_rt_cov_indicators(x)
   ats = sum(x[:, :ats] .== 1) .> 0
   otc = sum(x[:, :ats] .== 0) .> 0

   # Group 1: ATS, OTC or both
   ats_only = .&(ats, !otc)
   otc_only = .&(!ats, otc)
   ats_otc = .&(ats, otc)

   # Group 2: IG v.s. HY
   ig = sum(x[:, :ig] .== 1) .> 0
   hy = sum(x[:, :ig] .== 0) .> 0

   # Group 3: covenant v.s. no covenant
   cov = unique(x[:, :covenant])[1]

   df1 = DataFrame([:ats_only => ats_only, :otc_only => otc_only,
                    :ats_otc => ats_otc, :ig => ig, :hy => hy,
                    :cov => cov, :ncov => .!cov,
                    :ats_only_ig => .&(ats_only, ig), :otc_only_ig => .&(otc_only, ig),
                    :ats_otc_ig => .&(ats_otc, ig),
                    :ats_only_hy => .&(ats_only, hy), :otc_only_hy => .&(otc_only, hy),
                    :ats_otc_hy => .&(ats_otc, hy),
                    :ats_only_cov => .&(ats_only, cov), :otc_only_cov => .&(otc_only, cov),
                    :ats_otc_cov => .&(ats_otc, cov),
                    :ats_only_ncov => .&(ats_only, .!cov), :otc_only_ncov => .&(otc_only, .!cov),
                    :ats_otc_ncov => .&(ats_otc, .!cov),
                    :ig_cov => .&(ig, cov), :ig_ncov => .&(ig, .!cov),
                    :hy_cov => .&(hy, cov), :hy_ncov => .&(hy, .!cov),
                    :ats_only_ig_cov => .&(ats_only, ig, cov), :otc_only_ig_cov => .&(otc_only, ig, cov),
                    :ats_otc_ig_cov => .&(ats_otc, ig, cov),
                    :ats_only_hy_cov => .&(ats_only, hy, cov), :otc_only_hy_cov => .&(otc_only, hy, cov),
                    :ats_otc_hy_cov => .&(ats_otc, hy, cov),
                    :ats_only_ig_ncov => .&(ats_only, ig, .!cov), :otc_only_ig_ncov => .&(otc_only, ig, .!cov),
                    :ats_otc_ig_ncov => .&(ats_otc, ig, .!cov),
                    :ats_only_hy_ncov => .&(ats_only, hy, .!cov), :otc_only_hy_ncov => .&(otc_only, hy, .!cov),
                    :ats_otc_hy_ncov => .&(ats_otc, hy, .!cov)])


   # df2 = DataFrame(:ats_vol => sum(x[:, :ats] .* x[:, :entrd_vol_qt]),
   #                 :otc_vol => sum(.!x[:, :ats] .* x[:, :entrd_vol_qt]),
   #                 :ats_ig_vol => sum(x[:, :ats] .* x[:, :ig] .* x[:, :entrd_vol_qt]),
   #                 :ats_hy_vol => sum(x[:, :ats] .* .!x[:, :ig] .* x[:, :entrd_vol_qt]),
   #                 :otc_ig_vol => sum(.!x[:, :ats] .* x[:, :ig] .* x[:, :entrd_vol_qt]),
   #                 :otc_hy_vol => sum(.!x[:, :ats] .* .!x[:, :ig] .* x[:, :entrd_vol_qt]),
   #                 :ats_cov_vol => sum(x[:, :ats] .* x[:, :covenant] .* x[:, :entrd_vol_qt]),
   #                 :ats_ncov_vol => sum(x[:, :ats] .* .!x[:, :covenant] .* x[:, :entrd_vol_qt]),
   #                 :otc_cov_vol => sum(.!x[:, :ats] .* x[:, :covenant] .* x[:, :entrd_vol_qt]),
   #                 :otc_ncov_vol => sum(.!x[:, :ats] .* .!x[:, :covenant] .* x[:, :entrd_vol_qt]),
   #                 :ig_cov_vol => sum(x[:, :ig] .* x[:, :covenant] .* x[:, :entrd_vol_qt]),
   #                 :hy_cov_vol => sum(.!x[:, :ig] .*  x[:, :covenant] .* x[:, :entrd_vol_qt]),
   #                 :ig_ncov_vol => sum(x[:, :ig] .*  .!x[:, :covenant] .* x[:, :entrd_vol_qt]),
   #                 :hy_ncov_vol => sum(.!x[:, :ig] .* .!x[:, :covenant] .* x[:, :entrd_vol_qt]), )

    # Sum inner product function:
    sip(z...) = sum(.*(z...))

    # Varables
    va = x[:, :ats]
    vi = x[:, :ig]
    vc = x[:, :covenant]
    vv = x[:, :entrd_vol_qt]

    df2 = DataFrame(:ats_vol => sip(va, vv),
                    :otc_vol => sip(.!va, vv),
                    :ats_ig_vol => sip(va, vi, vv),
                    :ats_hy_vol => sip(va, .!vi, vv),
                    :otc_ig_vol => sip(.!va, vi, vv),
                    :otc_hy_vol => sip(.!va, .!vi, vv),
                    :ats_cov_vol => sip(va, vc, vv),
                    :ats_ncov_vol => sip(va, .!vc, vv),
                    :otc_cov_vol => sip(.!va, vc, vv),
                    :otc_ncov_vol => sip(.!va, .!vc, vv),
                    :ig_cov_vol => sip(vi, vc, vv),
                    :hy_cov_vol => sip(.!vi, vc, vv),
                    :ig_ncov_vol => sip(vi, .!vc, vv),
                    :hy_ncov_vol => sip(.!vi, .!vc, vv))

   # df2 = DataFrame([Symbol(y, :_vol) => df1[:, y] .* sum(x[:, :entrd_vol_qt])
   #                  for y in Symbol.(names(df1))])
   #
   return hcat(df1, df2)
end


function compute_indicators(df::DataFrame;
                            zvars::Dict{Symbol, Symbol}=Dict{Symbol, Symbol}(:entrd_vol_qt => :vol))
    df[!, :ats] = df[!, :ats_ind]
    df[!, :otc] = .!df[!, :ats_ind]
    df[!, :ig] = df[!, :ig_ind]
    df[!, :hy] = .!df[!, :ig_ind]
    df[!, :cov] = df[!, :cov_ind]
    df[!, :ncov] = .!df[!, :cov_ind]

    # Variable Combinations
    v1 = Array([[x] for x in [:ats, :otc, :ig, :hy, :cov, :ncov]])
    v2 = reshape([[x, y] for x in [:ats, :otc], y in [:ig, :hy]], 4, 1  )
    v3 = reshape([[x, y] for x in [:ats, :otc], y in [:cov, :ncov]], 4, 1)
    v4 = reshape([[x, y] for x in [:ig, :hy], y in [:cov, :ncov]], 4, 1)
    v5 = reshape([[x, y, z] for x in [:ats, :otc], y in [:ig, :hy], z in [:cov, :ncov]], 8, 1)
    vv = vcat(v1, v2, v3, v4, v5)

    for v in vv
        # Compute Boolean Arrays
        df[!, join(v, :_)] = .*([df[!, x] for x in v]...)

        # Compute Conditional Values
        if !isempty(zvars)
            for zk in keys(zvars)
                df[!, Symbol(join(v, :_), :_, get(zvars, zk, :na))] = .*([df[!, x] for x in vcat(v, zk)]...)
            end
        end
    end

    return df
end

function stats_by_yr_mo_issuer(df::DataFrame;
                               groups::Array{Symbol,1}=[:trd_exctn_yr, :trd_exctn_mo, :ISSUER_ID, :cusip_id],
                               indicators::Array{Symbol,1}=[:ats_ind, :cov_ind, :ig_ind],
                               zvars::Dict{Symbol, Symbol}=Dict{Symbol, Symbol}(:entrd_vol_qt => :vol))
    # Extract cols
    cols = vcat(groups, indicators, keys(zvars)...)
    adf = df[:, cols]

    # Boolean array indicators (ats/otc, ig/hy, cov/ncov)
    adf = compute_indicators(adf, zvars=zvars)

    # Variable Combinations
    # Boolean Columns
    bcols = [Symbol(x) for x in names(adf) if .&(!occursin("_ind", x),
                                                 !occursin("_vol", x),
                                                 !(Symbol(x) in groups))]
    # Volume Columns
    vcols = [Symbol(x) for x in names(adf) if .&(occursin("_vol", x),
                                                  x != "entrd_vol_qt")]

    # Group by yr, mo, issuer, cusip ====================================
    gd1 = groupby(adf,  groups)

    # Compute # trades and total volume by yr, mo, cusip
    # and (ats/otc, ig/hy, cov/ncov) categories
    adf1 = combine(gd1,
                   [x => count => x for x in bcols], # count trades by yr, mo, cusip
                   [x => sum => x for x in vcols],)  # sum volume by yr, mo, cusip
    # ===================================================================

    # Group by yr, mo, issuer ===========================================
    gd2 = groupby(adf1,  [x for x  in groups if (x != :cusip_id)])

    # Compute # cusips, # trades, and total volume by yr, mo, issuer
    # and (ats/otc, ig/hy, cov/ncov) categories
    return combine(gd2,
                   :cusip_id => (x -> size(unique(x), 1)) => :cusips,
                   [x => (x -> count(x .> 0)) => Symbol(x, :_cusips) for x in bcols],
                   [x => sum => Symbol(x, :_trades) for x in bcols],
                   [x => sum for x in vcols],)
    # ===================================================================
end
# }}}2
# }}}1
# Filtering Functions {{{1
# Main Functions {{{2
struct Filter
  sbm::Symbol
  rating::Symbol
  covenant::Symbol
end

function filter_constructor(sbm::Symbol, rating::Symbol, covenant::Symbol)
    sbm in (:ats, :otc, :both, :any) || error("invalid secondary bond market filter! \n",
                                              "Please enter :ats, :otc, :any or :both")
    rating in (:y, :n, :any) || error("invalid rating filter! \n", "Please enter :y, :n or :any")
    covenant in (:y, :n, :any) || error("invalid covenant filter! \n", "Please enter :y, :n or :any")

    return Filter(sbm, rating, covenant)
end

function gen_sbm_rt_cvt_cat_vars(df::DataFrame)
    sbmf(x, y) = (x == y == 1) ? :both : (x == y) ? :any : (x == 1) ? :ats : :otc
    covenantf(x, y) = (x == y) ? :any : (x == 1) ? :cov : :ncov
    ratingf(x, y) = (x == y) ? :any : (x == 1) ? :ig : :hy

    df[!, :sbm] .= sbmf.(df[:, :ats], df[:, :otc])
    df[!, :rt] .= ratingf.(df[:, :ig], df[:, :hy])
    df[!, :cvt] .= covenantf.(df[:, :cov], df[:, :ncov])

    return df
end

function get_ind_vec(ft)
    fd = Dict{Symbol, Array{Int64,1}}(:ats => [1, 0],
                                      :otc => [0, 1],
                                      :both => [1, 1],
                                      :y => [1, 0],
                                      :n => [0, 1],
                                      :any => [0, 0])

    vcat(fd[ft.sbm], fd[ft.rating], fd[ft.covenant])
end

function get_filter_comb(x1::Symbol, x2::Symbol, x3::Symbol;
                         co::Array{Symbol,1}=[:ats, :otc, :ig, :hy, :cov, :ncov])
    values = get_ind_vec(filter_constructor(x1, x2, x3))

    return DataFrame([co[i] => values[i] for i in 1:size(co, 1)])
end

function get_filter_combinations(; co::Array{Symbol,1}=[:ats, :otc, :ig, :hy, :cov, :ncov])
    avals = [:any, :ats, :otc, :both] # for secondary bond market
    vals = [:any, :y, :n] # for ig, covenant, convertible

    return vcat([get_filter_comb(x1, x2, x3; co=co) for x1 in avals, x2 in vals, x3 in vals]...)[:, co]
end

function dfrow2dict(df::DataFrame, row::Int64)
    cols = [x for x in Symbol.(names(df)) if !(x in [:sbm, :rt, :cvt])]

    return Dict{Symbol, Int64}([cn => df[row, cn] for cn in cols])
end

function get_filter_cond(df::DataFrame, x::Dict{Symbol,Int64})

    # Array of all true
    cond = typeof.(df[:, :ats]) .== Bool

    if .&(x[:ats] == 1, x[:otc] == 1)
        cond = .&(cond, df[:, :bond_ats_otc])
    else
        cond = x[:ats] .== x[:otc] ? cond : .&(cond, df[:, :ats] .== x[:ats])
    end

    cond = x[:ig] .== x[:hy] ? cond : .&(cond, df[:, :ig] .== x[:ig])
    cond = x[:cov] .== x[:ncov] ? cond : .&(cond, df[:, :covenant] .== x[:cov])

    return cond
end
# }}}2
# By Number of Covenants {{{2
function get_combination(sbm::Symbol, rt::Symbol;
                         combdf::DataFrame=DataFrame())

    if isempty(combdf)
        combdf =  StatsMod.get_filter_combinations()
    end

    id_cols = [:sbm, :rt, :cvt]
    if any([!(x in Symbol.(names(combdf))) for x in id_cols])
        combdf = StatsMod.gen_sbm_rt_cvt_cat_vars(combdf)
    end

    row = argmax(.&(combdf[:, :sbm] .== sbm,
                    combdf[:, :rt] .== rt,
                    combdf[:, :cvt] .== :any))

    cols = [x for x in Symbol.(names(combdf)) if !(x in id_cols)]
    return StatsMod.dfrow2dict(combdf[:, cols], row)
end

function stats_by_num_cov(df;
                      groupby_date_cols::Array{Symbol,1}=[:trd_exctn_yr, :trd_exctn_qtr])
    stats_cols = vcat(groupby_date_cols, :sbm, :rt, :cusip_id, :sum_num_cov)
    gdf1 = unique(df[:, stats_cols])
    df1 = combine(groupby(df, vcat(groupby_date_cols, :sbm, :rt)),
                  :sum_num_cov => (x -> Statistics.median(x)) => :median_num_cov,
                  :sum_num_cov => (x -> Statistics.mean(x)) => :mean_num_cov)

    gdf2 = groupby(df, vcat(groupby_date_cols, :sbm, :rt, :sum_num_cov))
    df2 = combine(gdf2,
            # Volume Statistics:
            :entrd_vol_qt => (x -> Statistics.mean(skipmissing(x))) => :mean_vol_by_num_cov,
            :entrd_vol_qt => (x -> Statistics.median(skipmissing(x))) => :median_vol_by_num_cov,
            :entrd_vol_qt => (x -> sum(skipmissing(x))/1e9) => :total_vol_by_num_cov,

            # Trade Count:
            :cusip_id => (x -> size(x, 1)) => :trades_by_num_cov,

            # Number of Bonds:
            :cusip_id => (x -> size(unique(x), 1)) => :bonds_by_num_cov,

            # Number of issuers:
            :ISSUER_ID => (x -> size(unique(x), 1)) => :issuers_by_num_cov)

    return sort!(innerjoin(df1, df2, on=vcat(groupby_date_cols, :sbm, :rt)),
                 vcat(groupby_date_cols, :sbm, :sum_num_cov))
end

function compute_stats_by_num_cov(df::DataFrame, sbm::Symbol,
                                  rt::Symbol, combdf::DataFrame;
                                  small_trades::Bool=false,
                                  small_trd_thrsd::Float64=1e5)
    combd = get_combination(sbm, rt; combdf=combdf)
    tmpdf =  deepcopy(df[get_filter_cond(df, combd), :])
    tmpdf[!, :sbm] .= sbm
    tmpdf[!, :rt] .= rt

    if small_trades
        cond = tmpdf[:, :entrd_vol_qt] .<= small_trd_thrsd
        tmpdf = tmpdf[cond, :]
    end

    return StatsMod.stats_by_num_cov(tmpdf)
end
# }}}2
# By Covenant Categories {{{2
function filter_selected(df::DataFrame;
                         date_cols::Array{Symbol, 1}=[:trd_exctn_yr, :trd_exctn_qtr],
                         extra_cols::Array{Symbol, 1}=Symbol[])
    bond_cols = [:ISSUER_ID, :cusip_id]
    filter_cols = vcat([:ats, :ig, :covenant],
                       [Symbol(x) for x in names(df) if occursin("cg", x)])
    trd_cols = [:entrd_vol_qt]
    cols = vcat(date_cols, bond_cols, filter_cols, trd_cols, extra_cols)

    # Keep only the selected securities
    df = df[df[:, :selected], cols]

    # Create indicator for bonds/issuers that trade
    # on both markets in the same period:
    colsl = vcat(date_cols, :cusip_id)
    tmp = combine(groupby(df, colsl),
                  :ats => (x -> .&(count(x) > 0, count(x .== false) > 0)) => :bond_ats_otc)
    df = innerjoin(df, tmp, on=colsl)

    colsl = vcat(date_cols, :ISSUER_ID)
    tmp = combine(groupby(df, colsl),
                          :bond_ats_otc => (x -> count(x) > 0) => :issuer_ats_otc)
    return innerjoin(df, tmp, on=colsl)
end


function vol_stats_generator(gdf)
    return combine(gdf, :entrd_vol_qt => (x -> Statistics.quantile!(x, .25)) => :qt25_trd_vol,
                        :entrd_vol_qt => mean => :mean_trd_vol,
                        :entrd_vol_qt => median => :median_trd_vol,
                        :entrd_vol_qt => (x -> Statistics.quantile!(x, .75)) => :qt75_trd_vol,
                        :entrd_vol_qt => (x -> sum(x)/1e9) => :total_trd_vol_tr)
end

# function cov_group_stats_generator(gdf)
#     cgcols = [Symbol(:cg, x) for x in 1:15]
#     cgvol(x) = sum(.*([getfield(x, col) for col in keys(x)]...))/1e9

#     return combine(gdf,
#                    [cg => count => Symbol(cg, :_trd_count) for cg in cgcols],
#                    [Symbol(cg,  :_bonds) => (x -> size(unique(x[.!ismissing.(x)]), 1)) => Symbol(cg, :_bonds) for cg in cgcols],
#                    [Symbol(cg,  :_issuers) => (x -> size(unique(x[.!ismissing.(x)]), 1)) => Symbol(cg, :_issuers) for cg in cgcols],
#                    [Symbol(cg,  :_trd_vol) => (x -> sum(x)/1e9) => Symbol(cg, :_trd_vol_tr) for cg in cgcols])
# end

# function stats_generator(df::DataFrame, combd::Dict{Symbol,Int64};
#                          groupbycols::Array{Symbol, 1}=[:trd_exctn_yr, :trd_exctn_qtr])
#     tmpdf = df[get_filter_cond(df, combd), :]

#     cgcols = [Symbol(:cg, x) for x in 1:15]
#     fx(b, x) = b ? x : missing
#     for cg in cgcols
#         tmpdf[!, Symbol(cg, :_trd_vol)] = .*(tmpdf[:, cg], tmpdf[:, :entrd_vol_qt])
#         tmpdf[!, Symbol(cg, :_bonds)] = fx.(tmpdf[:, cg], tmpdf[:, :cusip_id])
#         tmpdf[!, Symbol(cg, :_issuers)] = fx.(tmpdf[:, cg], tmpdf[:, :ISSUER_ID])
#     end

#     gdf = groupby(tmpdf, groupbycols)

#     # Number of bonds and number of trades
#     df1 = combine(gdf, nrow => :total_trd_count,
#                   :cusip_id => (x -> size(unique(x), 1)) => :total_bonds,
#                   :ISSUER_ID => (x -> size(unique(x), 1)) => :total_issuers)

#     # Volume stats
#     df2 = vol_stats_generator(gdf)

#     # Covenant Stats
#     df3 = cov_group_stats_generator(gdf)

#     # Join Stats DataFrames
#     sdf = innerjoin(innerjoin(df1, df2, on=groupbycols), df3, on=groupbycols)

#     # Reorder columns
#     cols1 =vcat(groupbycols, Symbol.(keys(combd)))
#     cols2 = [x for x in Symbol.(names(sdf)) if !(x in cols1)]
#     cols = vcat(cols1, cols2)
#     return hcat(sdf, repeat(DataFrame(combd), inner=size(df2, 1)))[:, cols]
# end

# Statistics by Covenant Categories:
function cg_vol_stats_generator(gdf)
    cgcols = [Symbol(x) for x in names(gdf) if .&(occursin("cg", x), !occursin("_", x))]


    f_mean(x) = !isempty(skipmissing(x)) ? Statistics.mean(skipmissing(x)) : NaN
    f_median(x) = !isempty(skipmissing(x)) ? Statistics.median(skipmissing(x)) : NaN
    f_vol(x) = !isempty(skipmissing(x)) ? sum(skipmissing(x))/1e9 : NaN
    return combine(gdf,
        # Volume Statistics:
        [Symbol(cg, :_trd_vol) => (x -> f_mean(x))  =>
            Symbol(cg, :_mean_trd_vol) for cg in cgcols],
        [Symbol(cg, :_trd_vol) => (x -> f_median(x)) =>
            Symbol(cg, :_median_trd_vol) for cg in cgcols],
        [Symbol(cg, :_trd_vol) => (x -> f_vol(x)) =>
            Symbol(cg, :_trd_vol_tr) for cg in cgcols],

        # Trade Count:
        [cg => count => Symbol(cg, :_trd_count) for cg in cgcols],

        # Number of Bonds:
        [Symbol(cg,  :_bonds) => (x -> size(unique(x[.!ismissing.(x)]), 1)) =>
            Symbol(cg, :_bonds) for cg in cgcols],

        # Number of issuers:
        [Symbol(cg,  :_issuers) => (x -> size(unique(x[.!ismissing.(x)]), 1)) =>
            Symbol(cg, :_issuers) for cg in cgcols])
end

function stats_generator(df::DataFrame, combd::Dict{Symbol,Int64};
                         groupby_date_cols::Array{Symbol, 1}=[:trd_exctn_yr, :trd_exctn_qtr],
                         small_trades::Bool=false,
                         small_trd_thrsd::Float64=1e5)
    tmpdf = df[get_filter_cond(df, combd), :]

    if small_trades
        cond = tmpdf[:, :entrd_vol_qt] .<= small_trd_thrsd
        tmpdf = tmpdf[cond, :]
    end

    cgcols = [Symbol(:cg, x) for x in 1:15]
    fx1(dummy, var) = dummy == true ? var : 0.0
    fx2(dummy, var) = dummy == true ? var : missing
    for cg in cgcols
        tmpdf[!, Symbol(cg, :_trd_vol)] = fx1.(tmpdf[:, cg],
                                               tmpdf[:, :entrd_vol_qt])
        tmpdf[!, Symbol(cg, :_bonds)] = fx2.(tmpdf[:, cg],
                                             tmpdf[:, :cusip_id])
        tmpdf[!, Symbol(cg, :_issuers)] = fx2.(tmpdf[:, cg],
                                               tmpdf[:, :ISSUER_ID])
    end

    gdf = groupby(tmpdf, groupby_date_cols)

    # Number of bonds and number of trades
    df1 = combine(gdf, nrow => :total_trd_count,
                  :cusip_id => (x -> size(unique(x), 1)) => :total_bonds,
                  :ISSUER_ID => (x -> size(unique(x), 1)) => :total_issuers)

    # Volume stats
    df2 = vol_stats_generator(gdf)

    # Statistics by Covenant Categories
    df3 = cg_vol_stats_generator(gdf)

    # Join Stats DataFrames
    sdf = innerjoin(innerjoin(df1, df2, on=groupby_date_cols), df3, on=groupby_date_cols)

    # Reorder columns
    cols1 =vcat(groupby_date_cols, Symbol.(keys(combd)))
    cols2 = [x for x in Symbol.(names(sdf)) if !(x in cols1)]
    cols = vcat(cols1, cols2)
    return hcat(sdf, repeat(DataFrame(combd), inner=size(df2, 1)))[:, cols]
end
# }}}2
# }}}1
# Tables {{{1
# Auxiliary Functions {{{2
function str_formatter(x::String)
    xvec = split(x, "_")
    if xvec[1] == "all"
        return "All"
    else
        return size(xvec, 1) == 1 ? uppercase(x) : join(uppercasefirst.(xvec), "")
    end
end

function ff1(x)
    if typeof(x) == Float64
        return @printf("%.2f", x)
    elseif typeof(x) == Int64
        println("here")
        return @printf("%.0f", x)
    else
        return @printf("%s", x)
    end
end
# }}}2
# Tags {{{2
struct Tags
    sbmf::Function
    crf::Function
    covf::Function
    tag::Function
end

function tag_functions_constructor()
    # Secondary Bond Market Indicator
    sbmf(x::Int64) = Dict{Int64, Symbol}(0 => :otc, 1 => :ats, 2 => :all)[x]

    # Credit Rating Indicator
    crf(x::Int64) = Dict{Int64, Symbol}(0 => :hy, 1 => :ig, 2 => :all)[x]

    # Covenant Presence Indicator
    covf(x::Int64) = Dict{Int64, Symbol}(0 => :ncov, 1 => :cov, 2 => :all)[x]

    tag(x::Int64, y::Int64, z::Int64) = Symbol(sbmf(x), :_, crf(y), :_, covf(z))

    return Tags(sbmf, crf, covf, tag)
end
# }}}2
# Computations {{{2
function compute_stats(df, gbvars::Array{Symbol, 1};
                       small_trades_threshold::Float64=1e5,
                       svars::Array{Symbol, 1}=[:bond_count,
                                                :trade_count,
                                                :trade_volume,
                                                :median_trade_volume,
                                                :small_trade_count,
                                                :small_trade_count_share,
                                                :small_trade_volume,
                                                :small_trade_volume_share])

    # cf(df) = combine(df,
    #               # Number of Bonds
    #               :cusip_id => (x -> size(unique(x), 1)) => :bond_count,
    #               # Trade Count
    #               nrow => :trade_count,
    #               # Trade Volume in USD tn
    #               :entrd_vol_qt => (x -> sum(x)/1e9) => :trade_volume)

    cf(df) = combine(df,
                      # Number of Bonds
                      :cusip_id => (x -> size(unique(x), 1)) => :bond_count,
                      # Trade Count
                      nrow => :trade_count,
                      # Small Trades Count
                      :entrd_vol_qt => (x -> count(x .<= small_trades_threshold)) => :small_trade_count,
                      # Trade Volume in USD tn
                      :entrd_vol_qt => (x -> sum(x)/1e9) => :trade_volume,
                      # Small Trades Volume in USD tn
                      :entrd_vol_qt => (x -> sum(x[x .<= small_trades_threshold])/1e9) => :small_trade_volume,
                      # Median Trade Volume
                      :entrd_vol_qt => (x -> Statistics.median(x)) => :median_trade_volume)

    sdf = isempty(gbvars) ? cf(df) : sort!(cf(groupby(df, gbvars)), gbvars, rev=true)


    for var in [:trade_count, :trade_volume]
        sdf[!, Symbol(:small_, var, :_share)] = (sdf[!, Symbol(:small_, var)]./sdf[!, var]).*100
    end

    for col in [:ats, :ig, :covenant]
        if !(col in gbvars)
            sdf[!, col] .= 2
        end
    end

    gbvars = [:ats, :ig, :covenant]
    for col in gbvars
        sdf[!, col] = Int64.(sdf[:, col])
    end

    # Tags
    ts = tag_functions_constructor()
    sdf[:, :sbm_rt_cov] = ts.tag.(Int64.(sdf[!, :ats]),
                                  Int64.(sdf[!, :ig]),
                                  Int64.(sdf[!, :covenant]))

    # Reorder columns:
    sdf = sdf[:, vcat(gbvars, :sbm_rt_cov, svars)]

    return sdf
end

function form_stats_table(sdf::DataFrame)
    ts = tag_functions_constructor()
    sdf[:, :sbm] = ts.sbmf.(sdf[:, :ats])
    sdf[:, :cr] = ts.crf.(sdf[:, :ig])
    sdf[:, :cov] = ts.covf.(sdf[:, :covenant])

    # Keep Only Cases where covenant = all
    df = sdf[sdf[:, :covenant] .== 2, :]

    # Drop columns
    df = df[:, Not([:ats, :ig, :covenant, :sbm_rt_cov, :cov])]

    # Reshape
    df = unstack(stack(df, [:bond_count, :trade_count, :trade_volume]),
                [:variable, :cr], :sbm, :value)

    # Compute Ratios
    df[!, :ats_otc] = (df[!, :ats]./df[!, :otc]) .* 100
    df[!, :ats_total] = (df[!, :ats]./df[!, :all]) .* 100
    df[!, :otc_total] = (df[!, :otc]./df[!, :all]) .* 100

    # Sort Data
    ff(x) = Dict(:ig => 0, :hy => 1, :all => 2)[x]
    cols = [:variable, :cr, :ats, :otc, :all,
            :ats_otc, :ats_total, :otc_total]
    return sort!(df, [:variable, order(:cr, by=ff)])[:, cols]
end
# }}}2
# Small Trades Table {{{2
function small_trades_df_reshaper(df::DataFrame;
                                  small_trades::Bool=true,
                                  abs_values::Bool=true)
    # Function to rename rows:
    rf(x) = join([x for x in split(string(x), "_") if !(x in ["small", "share"])], "_")

    # Choose small trades or total trades, absolute values or shares:
    vt1 = small_trades ? :small_ : Symbol("")
    vt2 = abs_values ? Symbol("") : :_share
    yvar = Symbol(vt1, :trade)

    df2 = unstack(stack(df, [Symbol(yvar, :_count, vt2), Symbol(yvar, :_volume, vt2)]),
                [:variable, :cr], :sbm, :value)
    ff(x) = Dict(:ig => 0, :hy => 1, :all => 2)[x]
    sort!(df2, [:variable, order(:cr, by=ff)])

    # Rename Rows
    df2[!, :variable] = rf.(df2[!, :variable])

    # Rename Columns
    rename!(df2, [x => Symbol(yvar, vt2, :_, x) for x in [:ats, :otc, :all]])

    # Reorder Columns
    df2 = df2[:, vcat([:variable, :cr], [Symbol(yvar, vt2,:_, x) for x in [:ats, :otc, :all]])]

    return df2
end

function small_trades_stats(sdf::DataFrame)
    ts = tag_functions_constructor()
    sdf[:, :sbm] = ts.sbmf.(sdf[:, :ats])
    sdf[:, :cr] = ts.crf.(sdf[:, :ig])
    sdf[:, :cov] = ts.covf.(sdf[:, :covenant])

    # Keep Only Cases where covenant = all
    df = sdf[sdf[:, :covenant] .== 2, :]

    # Drop columns
    df = df[:, Not([:ats, :ig, :covenant, :sbm_rt_cov, :cov])]

    # Form Tables
    tdf1 = small_trades_df_reshaper(df; small_trades=true, abs_values=true)
    tdf2 = small_trades_df_reshaper(df; small_trades=false, abs_values=true)
    tdf3 = small_trades_df_reshaper(df; small_trades=true, abs_values=false)

    tdf = outerjoin(outerjoin(tdf1, tdf2; on = [:variable, :cr]),
                    tdf3; on = [:variable, :cr])

    # Reorder Columns
    cols = vcat([Symbol(x, :_, y) for x in [:small_trade, :trade, :small_trade_share], y in [:ats, :otc, :all]]...)
    return tdf[:, vcat(:variable, :cr, cols)]
end
# }}}2
# Generator {{{2
function gen_trade_stats_tables(df::DataFrame, gbvars_vec::Array{Array{Symbol, 1}, 1})
    combdf = get_filter_combinations()
    combdf = gen_sbm_rt_cvt_cat_vars(combdf)
    if !any([:covenant in x for x in gbvars_vec])
        # do not discriminate on the basis of covenants:
        combdf = combdf[combdf[:, :cvt] .== :any, :]
    end

    # Generate Statistics
    @time sdf_vec = fetch(@spawn [compute_stats(df, gbvars)
                                  for gbvars in gbvars_vec])
    sdf = vcat(sdf_vec...)

    # Form Tables - All trades
    atdf = form_stats_table(sdf)
    atdf[!, :variable] = str_formatter.(convert.(String, atdf[!, :variable]))
    atdf[!, :cr] = str_formatter.(string.(atdf[!, :cr]))

    # Form Tables - Small Trades
    stdf = StatsMod.small_trades_stats(sdf)

    # Format Tables
    # for tdf in [atdf, stdf]
    #     tdf[!, :variable] = str_formatter.(convert.(String, tdf[!, :variable]))
    #     tdf[!, :cr] = str_formatter.(string.(tdf[!, :cr]))
    # end

    return sdf, atdf, stdf
end
# }}}2
# LaTeX and Markdown Printers {{{2
function markdown_tables_printer(df::DataFrame)
    for x in unique(df[:, :variable])
        cond = df[:, :variable] .== x
        # fmt = x == "TradeVolume" ? "%'.2f" : "%'d"
        fmt = "%'.2f"
        println(x)
        latexify(df[cond, Not(:variable)]; fmt=fmt, env=:mdtable) |> print
    end
end
# }}}2
# }}}1
# Storing and Retrieving the Results {{{1
function save_stats_data(dto, df::DataFrame; small_trades=false)
    stats_data_path = string(dto.main_path, "/", dto.data_dir, "/", dto.stats_dir)
    yr_dir = string(minimum(df[:, :trd_exctn_yr]))
    if !isdir(stats_data_path)
        mkdir(stats_data_path)
    end
    if !isdir(string(stats_data_path, "/", yr_dir))
        mkdir(string(stats_data_path, "/", yr_dir))
    end

    # Get date columns identifier
    date_cols = [Symbol(x) for x in names(df) if
                any([occursin(y, x) for y in ["yr", "qtr", "mo"]])]
    fd(x) = occursin("yr", string(x)) ? "" : occursin("qtr", string(x)) ? :Q : :m
    dateid = Symbol([Symbol(fd(x), Int64(minimum(df[:, x]))) for x in date_cols]...)

    # Type of Statistics
    # type 1: by number of covenants
    # type 2: by covenant category
    type2_cond = all([any([occursin(string("cg", x), y) for y in names(df)]) for x in 1:15])
    dftype =  "stats_by_num_cov"
    if type2_cond
        dftype =  "stats_by_cov_cat"
    end


    stname = small_trades ? "_small_trades" : ""
    fname = string(dateid, "_", dftype, stname, ".csv")
    println(" ")
    println("Filename: ", fname)
    println(" ")
    println("Saving dataframe to folder: ", string(stats_data_path, "/", yr_dir), "...")
    CSV.write(string(stats_data_path, "/", yr_dir, "/", fname), df)
    println("Done!")
end

function load_stats_data(dto, yr::Int64, qtr::Int64; stats_by_num_cov::Bool=true)
    stats_data_path = string(dto.main_path, "/", dto.data_dir, "/", dto.stats_dir)
    yr_dir = yr
    if !isdir(stats_data_path)
        mkdir(stats_data_path)
    end
    if !isdir(string(stats_data_path, "/", yr_dir))
        mkdir(string(stats_data_path, "/", yr_dir))
    end

    dateid = Symbol(yr, :Q, qtr)

    # Type of Statistics
    dftype = "stats_by_num_cov"
    if !stats_by_num_cov
        dftype = "stats_by_cov_cat"
    end

    fname = string(dateid, "_", dftype, ".csv")
    println(" ")
    println("Filename: ", fname)
    println(" ")
    println("Reading dataframe in folder: ", string(stats_data_path, "/", yr_dir), "...")
    df = DataFrame(CSV.File(string(stats_data_path, "/", yr_dir, "/", fname)))

    # Parse Columns
    columns = [x for x in [:sbm, :rt, :cvt] if x in Symbol.(names(df))]
    for col in columns
        df[!, col] = Symbol.(df[:, col])
    end
    # trade execution quarter should be an integer:
    df[!, :trd_exctn_qtr] = Int64.(df[!, :trd_exctn_qtr])

    return df
end
# }}}1
# Stats DataFrames {{{1
# Stats by Covenant Categories {{{2
function get_stats_by_cov_cat_df(dto, df::DataFrame;
                                 date_cols::Array{Symbol, 1}=[:trd_exctn_yr,
                                                               :trd_exctn_qtr],
                                 small_trades::Bool=false,
                                 small_trd_thrsd::Float64=1e5,
                                 save_data::Bool=true)
    combdf = get_filter_combinations()

    # Compute Stats
    @time dfl_qtr = fetch(@spawn [stats_generator(df,
                                   dfrow2dict(combdf, row);
                                   groupby_date_cols=date_cols,
                                   small_trades=small_trades,
                                  small_trd_thrsd=small_trd_thrsd)
                                  for row in 1:size(combdf, 1)])
    scc = sort(vcat(dfl_qtr...), names(combdf))
    scc = gen_sbm_rt_cvt_cat_vars(scc)

    if save_data
        save_stats_data(dto, scc; small_trades=small_trades)
    end

    return scc
end
# }}}2
# Stats by Number of Covenants {{{2
function get_stats_by_num_cov_df(dto, df::DataFrame;
                                 small_trades::Bool=false,
                                 small_trd_thrsd::Float64=1e5,
                                 save_data::Bool=true)

    combdf = get_filter_combinations()
    combdf = gen_sbm_rt_cvt_cat_vars(combdf)

    # Count the number of covenants in each bond:
    df[!, :sum_num_cov] .= sum([df[:, Symbol(:cg, x)] for x in 1:15])

    # Compute Stats
    @time dfl = fetch(Distributed.@spawn [compute_stats_by_num_cov(df,
                                            sbm, rt, combdf;
                                            small_trades=small_trades,
                                            small_trd_thrsd=small_trd_thrsd) for
                    sbm in [:any, :ats, :otc], rt in [:any, :ig, :hy]])

    snc = vcat(dfl...)

    if save_data
        save_stats_data(dto, snc; small_trades=small_trades)
    end

    return snc
end

function num_cov_filter_df(df::DataFrame, var::Symbol, sbm::Array{Symbol,1};
                  rt::Array{Symbol,1}=[:any],
                  yr::Int64=0,
                  qtr::Int64=0)

    # Check Year
    if yr == 0
        yr = unique(df[:, :trd_exctn_yr])[1]
        if size(unique(df[:, :trd_exctn_yr]), 1) > 1
            println("Attention! More than one year in the data! Selecting year: ", yr)
        end
    end

    # Check quarter
    if qtr == 0
        cond = abs.(df[:, :trd_exctn_yr] .- yr) .< 1e-5
        qtr = unique(df[cond, :trd_exctn_qtr])[1]
        if size(unique(df[cond, :trd_exctn_yr]), 1) > 1
            println("Attention! More than one quarter in the data! Selecting quarter: ", yr)
        end
    end

    # Select Year, Quarter, Credit Rating and Secondary Bond Market:
    filter_cond = .&(abs.(df[:, :trd_exctn_yr] .- yr) .< 1e-5,
                     abs.(df[:, :trd_exctn_qtr] .- qtr) .< 1e-5,
                     in(rt).(df[:, :rt]),
                     in(sbm).(df[:, :sbm]))

    # Select Columns
    cols = vcat([:trd_exctn_yr, :trd_exctn_qtr, :sbm, :rt, :sum_num_cov],
                [Symbol(x) for x in names(df) if occursin(string(var), x)])

    # Filter
    return df[filter_cond, cols]
end

function num_cov_filter_groups(df::DataFrame, var::Symbol;
                               sbm_vec::Array{Symbol, 1}=[:any],
                               rt_vec::Array{Symbol, 1}=[:any],
                               min_num_cov::Int64=5,
                               max_num_cov::Int64=9)


    # GROUP SBM: Select ATS, OTC or ANY
    sbm_cond(x, sbm) = x[:, :sbm] .== sbm

    # GROUP RT: Select IG, HY or ANY
    rt_cond(x, rt) = x[:, :rt] .== rt

    # Group SBM+RT
    sbm_rt_cond(x, sbm, rt) = .&(sbm_cond(x, sbm), rt_cond(x, rt))

    # Mininum and Maximum Number of Covenant Categories
    num_cov_cond(x, min_num_cov, max_num_cov) = .&(x[:, :sum_num_cov] .>= min_num_cov,
                                                   x[:, :sum_num_cov] .<= max_num_cov)

    # GROUP SBM+RT+NUM_COV: SBM + RT + Covenant Categories Bounds
    sbm_rt_cov_cond(x, sbm, rt, min_num_cov, max_num_cov) = .&(sbm_rt_cond(x, sbm, rt),
                                                               num_cov_cond(x, min_num_cov, max_num_cov))

    # Get Share of GROUP SBM+RT+NUM_COV w.r.t Total in GROUP SBM+RT
    tmpf(x, varname, sbm, rt, min_num_cov, max_num_cov) = sum(x[sbm_rt_cov_cond(x, sbm, rt, min_num_cov, max_num_cov),
                                                                varname])/sum(x[sbm_rt_cond(x, sbm, rt), varname])

    # # Compute Shares for each SBM
    # tmpf2(x, varname, sbm_vec, rt_vec, min_num_cov, max_num_cov) = [tmpf(x, varname, sbm, rt, min_num_cov, max_num_cov)
    #                                                                 for sbm in sbm_vec, rt in rt_vec]

    varname=Symbol(var, :_by_num_cov)
    df2 = DataFrame()
    for sbm in sbm_vec
        for rt in rt_vec
            tmp = combine(x -> tmpf(x, varname, sbm, rt, min_num_cov, max_num_cov), df)
            rename!(tmp, [Symbol(var, :_share)])
            tmp[:, :sbm] .= sbm
            tmp[:, :rt] .= rt
            df2 = vcat(df2, tmp)
        end
    end

    return df2
end

function num_cov_get_shares(df::DataFrame, var::Symbol;
                    sbm_vec::Array{Symbol, 1}=[:any],
                    rt_vec::Array{Symbol, 1}=[:any],
                    min_num_cov::Int64=5,
                    max_num_cov::Int64=9)

    # Filter DataFrame on Secondary Bond Market and Credit Rating
    tmp = num_cov_filter_df(df, var, sbm_vec; rt=rt_vec)

    # Compute Shares
    df2 = num_cov_filter_groups(tmp, var; sbm_vec=sbm_vec, rt_vec=rt_vec,
                                min_num_cov=min_num_cov, max_num_cov=max_num_cov)

    return df2
end
# }}}2
# }}}1
end
