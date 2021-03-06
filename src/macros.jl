using JuMP
import JuMP: getvalue, validmodel, addtoexpr_reorder
using Base.Meta

export @polyvariable, @polyconstraint

function getvalue{C}(p::Polynomial{C, JuMP.Variable})
    Polynomial(map(getvalue, p.a), p.x)
end
function getvalue{C}(p::MatPolynomial{C, JuMP.Variable})
    MatPolynomial(map(getvalue, p.Q), p.x)
end

polyvariable_error(args, str) = error("In @polyvariable($(join(args, ","))): ", str)

macro polyvariable(args...)
    length(args) <= 1 &&
    polyvariable_error(args, "Expected model as first argument, then variable information.")
    m = esc(args[1])
    x = args[2]
    extra = vcat(args[3:end]...)

    t = :Cont
    gottype = false
    haslb = false
    hasub = false
    # Identify the variable bounds. Five (legal) possibilities are "x >= lb",
    # "x <= ub", "lb <= x <= ub", "x == val", or just plain "x"
    explicit_comparison = false
    if isexpr(x,:comparison) # two-sided
        polyvariable_error(args, "Polynomial variable declaration does not support the form lb <= ... <= ub. Use ... >= 0 and separate constraints instead.")
    elseif isexpr(x,:call)
        explicit_comparison = true
        if x.args[1] == :>= || x.args[1] == :≥
            # x >= lb
            var = x.args[2]
            @assert length(x.args) == 3
            lb = JuMP.esc_nonconstant(x.args[3])
            if lb != 0
                polyvariable_error(args, "Polynomial variable declaration does not support the form ... >= lb with nonzero lb.")
            end
            nonnegative = true
        elseif x.args[1] == :<= || x.args[1] == :≤
            # x <= ub
            # NB: May also be lb <= x, which we do not support
            #     We handle this later in the macro
            polyvariable_error(args, "Polynomial variable declaration does not support the form ... <= ub.")
        elseif x.args[1] == :(==)
            polyvariable_error(args, "Polynomial variable declaration does not support the form ... == value.")
        else
            # Its a comparsion, but not using <= ... <=
            polyvariable_error(args, "Unexpected syntax $(string(x)).")
        end
    else
        # No bounds provided - free variable
        # If it isn't, e.g. something odd like f(x), we'll handle later
        var = x
        nonnegative = false
    end

    # separate out keyword arguments
    if VERSION < v"0.6.0-dev.1934"
        kwargs = filter(ex-> isexpr(ex,:kw), extra)
        extra  = filter(ex->!isexpr(ex,:kw), extra)
    else
        kwargs = filter(ex-> isexpr(ex,:(=)), extra)
        extra  = filter(ex->!isexpr(ex,:(=)), extra)
    end

    quotvarname = quot(getname(var))
    escvarname  = esc(getname(var))

    monotype = :None

    # process keyword arguments
    gram = false
    for ex in kwargs
        kwarg = ex.args[1]
        if kwarg == :grammonomials
            if monotype != :None
                polyvariable_error("Monomials given twice")
            end
            monotype = :Gram
            x = esc(ex.args[2])
        elseif kwarg == :monomials
            if monotype != :None
                polyvariable_error("Monomials given twice")
            end
            monotype = :Classic
            x = esc(ex.args[2])
        else
            polyvariable_error(args, "Unrecognized keyword argument $kwarg")
        end
    end

    # Determine variable type (if present).
    # Types: default is continuous (reals)
    if isempty(extra)
        if monotype == :None
            polyvariable_error(args, "Missing monomial vector")
        end
    elseif length(extra) > 1
        polyvariable_error(args, "Too many extra argument: only expected monomial vector")
    else
        if monotype != :None
            polyvariable_error(args, "Monomials given twice")
        end
        monotype = :Default
        x = esc(extra[1])
    end
    Z = gensym()

    @assert monotype != :None

    create_fun = nonnegative ? :createnonnegativepoly : :createpoly

    # This is ugly I know
    monotypeid = monotype == :Default ? 1 : (monotype == :Classic ? 2 : 3)
    monotype = gensym()

    if isa(var,Symbol)
        # Easy case - a single variable
        return JuMP.assert_validmodel(m, quote
            $monotype = [:Default, :Classic, :Gram][$monotypeid]
            $escvarname = getpolymodule($m).$create_fun($m, $monotype, $x)
        end)
    else
        polyvariable_error(args, "Invalid syntax for variable name: $(string(var))")
    end
end

polyconstraint_error(m, x, args, str) = error("In @polyconstraint($m, $x$(isempty(args) ? "" : ", " * join(args, ","))): ", str)

function appendconstraints!(m, x, args, domaineqs, domainineqs, expr::Expr)
    if isexpr(expr, :call)
        sense, vectorized = JuMP._canonicalize_sense(expr.args[1])
        @assert !vectorized
        if sense == :(>=)
            push!(domainineqs, :($(expr.args[2]) - $(expr.args[3])))
        elseif sense == :(<=)
            push!(domainineqs, :($(expr.args[3]) - $(expr.args[2])))
        elseif sense == :(==)
            push!(domaineqs, :($(expr.args[2]) - $(expr.args[3])))
        else
            polyconstraint_error(m, x, args, "Unrecognized sense $(string(sense)) in domain specification")
        end
    elseif isexpr(expr, :&&)
        map(t -> appendconstraints!(m, x, args, domaineqs, domainineqs, t), expr.args)
    else
        polyconstraint_error(m, x, args, "Invalid domain constraint specification $(string(expr))")
    end
    nothing
end

macro polyconstraint(m, x, args...)
    if isa(x, Symbol)
        polyconstraint_error(m, x, args, "Incomplete constraint specification $x. Are you missing a comparison (<= or >=)?")
    end

    (x.head == :block) &&
    polyconstraint_error(m, x, args, "Code block passed as constraint.")
    isexpr(x,:call) && length(x.args) == 3 || polyconstraint_error(m, x, args, "constraints must be in one of the following forms:\n" *
                                                                   "       expr1 <= expr2\n" * "       expr1 >= expr2")

    domaineqs = []
    domainineqs = []
    hasdomain = false
    for arg in args
        if ((VERSION < v"0.6.0-dev.1934") && !isexpr(arg, :kw)) || (VERSION >= v"0.6.0-dev.1934" && !isexpr(arg, :(=)))
            polyconstraint_error(m, x, args, "Unrecognized extra argument $(string(arg))")
        end
        if arg.args[1] == :domain
            @assert length(arg.args) == 2
            hasdomain && polyconstraint_error(m, x, args, "Multiple domain keyword arguments")
            hasdomain = true
            appendconstraints!(m, x, args, domaineqs, domainineqs, arg.args[2])
        else
            polyconstraint_error(m, x, args, "Unrecognized keyword argument $(string(arg))")
        end
    end

    # Build the constraint
    # Simple comparison - move everything to the LHS
    sense = x.args[1]
    if sense == :⪰
        sense = :(>=)
    elseif sense == :⪯
        sense = :(<=)
    end
    sense,_ = JuMP._canonicalize_sense(sense)
    lhs = :()
    if sense == :(>=) || sense == :(==)
        lhs = :($(x.args[2]) - $(x.args[3]))
    elseif sense == :(<=)
        lhs = :($(x.args[3]) - $(x.args[2]))
    else
        polyconstraint_error(m, x, args, "Invalid sense $sense")
    end
    newaff, parsecode = JuMP.parseExprToplevel(lhs, :q)
    nonnegative = !(sense == :(==))
    code = quote
        q = zero(AffExpr)
        $parsecode
    end
    domainaffs = gensym()
    code = quote
        $code
        $domainaffs = BasicSemialgebraicSet()
    end
    for dom in domaineqs
        affname = gensym()
        newaffdomain, parsecodedomain = JuMP.parseExprToplevel(dom, affname)
        code = quote
            $code
            $affname = zero(Polynomial{true, Int})
            $parsecodedomain
            addequality!($domainaffs, $newaffdomain)
        end
    end
    for dom in domainineqs
        affname = gensym()
        newaffdomain, parsecodedomain = JuMP.parseExprToplevel(dom, affname)
        code = quote
            $code
            $affname = zero(Polynomial{true, Int})
            $parsecodedomain
            addinequality!($domainaffs, $newaffdomain)
        end
    end
    # I escape m here so that is is not escaped in the error messages of polyconstraint_error
    m = esc(m)
    JuMP.assert_validmodel(m, quote
        $code
        addconstraint($m, PolyConstraint($newaff, $nonnegative, getpolymodule($m), $domainaffs))
    end)
end
