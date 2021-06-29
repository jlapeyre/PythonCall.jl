struct PyConvertRule
    type :: Type
    func :: Function
    priority :: Int
end

const PYCONVERT_RULES = Dict{String, Vector{PyConvertRule}}()

function pyconvert_add_rule(pytypename::String, type::Type, func::Function, priority::Int=0)
    @nospecialize type func
    push!(get!(Vector{PyConvertRule}, PYCONVERT_RULES, pytypename), PyConvertRule(type, func, priority))
    return
end

if false
    struct Unconverted end
    pyconvert_return(x) = x
    pyconvert_unconverted() = Unconverted()
    pyconvert_returntype(::Type{T}) where {T} = Union{T,Unconverted}
    pyconvert_isunconverted(r) = r === Unconverted()
    pyconvert_result(r) = r
else
    const PYCONVERT_RESULT = Ref{Any}(nothing)
    pyconvert_return(x) = (PYCONVERT_RESULT[] = x; true)
    pyconvert_unconverted() = false
    pyconvert_returntype(::Type{T}) where {T} = Bool
    pyconvert_isunconverted(r::Bool) = !r
    pyconvert_result(r::Bool) = (ans = PYCONVERT_RESULT[]; PYCONVERT_RESULT[] = nothing; ans)
end

pyconvert_tryconvert(::Type{T}, x::T) where {T} = pyconvert_return(x)
pyconvert_tryconvert(::Type{T}, x) where {T} =
    try
        pyconvert_return(convert(T, x)::T)
    catch
        pyconvert_unconverted()
    end


function pyconvert_get_rules(type::Type, pytype::Py)
    @nospecialize type

    # get the names of the types in the MRO of pytype
    mro = String["$(t.__module__)/$(t.__qualname__)" for t in pytype.__mro__]

    # get corresponding rules
    rules = PyConvertRule[rule for tname in mro for rule in get!(Vector{PyConvertRule}, PYCONVERT_RULES, tname)]

    # order the rules by priority, then by original order
    order = sort(axes(rules, 1), by = i -> (-rules[i].priority, i))
    rules = rules[order]

    # intersect rules with type
    rules = PyConvertRule[PyConvertRule(typeintersect(rule.type, type), rule.func, rule.priority) for rule in rules]

    # explode out unions
    rules = [PyConvertRule(type, rule.func, rule.priority) for rule in rules for type in Utils.explode_union(rule.type)]

    # filter out empty rules
    rules = [rule for rule in rules if rule.type != Union{}]

    # filter out repeated rules
    rules = [rule for (i, rule) in enumerate(rules) if !any((rule.func === rules[j].func) && ((rule.type) <: (rules[j].type)) for j in 1:(i-1))]

    # @info "pyconvert" rules
    return Function[pyconvert_fix(rule.type, rule.func) for rule in rules]
end

pyconvert_fix(::Type{T}, func) where {T} = x -> func(T, x)

const PYCONVERT_RULES_CACHE = Dict{C.PyPtr, Dict{Type, Vector{Function}}}()

function pyconvert_rule_fast(::Type{T}, x::Py) where {T}
    if T isa Union
        a = pyconvert_rule_fast(T.a, x) :: pyconvert_returntype(T.a)
        pyconvert_isunconverted(a) || return a
        b = pyconvert_rule_fast(T.b, x) :: pyconvert_returntype(T.b)
        pyconvert_isunconverted(b) || return b
    end
    pyconvert_unconverted()
end

pytryconvert(::Type{T}, x) where {T} = @autopy x begin
    # We can optimize the conversion for some types by overloading pytryconvert_fast.
    # It MUST give the same results as via the slower route using rules.
    ans = pyconvert_rule_fast(T, getpy(x_)) :: pyconvert_returntype(T)
    pyconvert_isunconverted(ans) || return ans
    # get rules from the cache
    # TODO: we should hold weak references and clear the cache if types get deleted
    tptr = C.Py_Type(getptr(x_))
    trules = get!(Dict{Type, Vector{PyConvertRule}}, PYCONVERT_RULES_CACHE, tptr)
    if !haskey(trules, T)
        t = pynew(incref(tptr))
        trules[T] = pyconvert_get_rules(T, t)
        pydel!(t)
    end
    rules = trules[T]
    # apply the rules
    for rule in rules
        ans = rule(getpy(x_)) :: pyconvert_returntype(T)
        pyconvert_isunconverted(ans) || return ans
    end
    return pyconvert_unconverted()
end

pyconvert(::Type{T}, x) where {T} = @autopy x begin
    ans = pytryconvert(T, x_)
    if pyconvert_isunconverted(ans)
        error("cannot convert this Python '$(pytype(x_).__name__)' to a Julia '$T'")
    else
        pyconvert_result(ans)::T
    end
end
pyconvert(::Type{T}, x, d) where {T} = @autopy x begin
    ans = pytryconvert(T, x_)
    if pyconvert_isunconverted(ans)
        d
    else
        pyconvert_result(ans)::T
    end
end
export pyconvert

pyconvertarg(::Type{T}, x, name) where {T} = @autopy x begin
    ans = pytryconvert(T, x_)
    if pyconvert_isunconverted(ans)
        errset(pybuiltins.TypeError, "Cannot convert argument '$name' to a Julia '$T', got a '$(pytype(x_).__name__)'")
        pythrow()
    else
        pyconvert_result(ans)::T
    end
end

function init_pyconvert()
    # priority 300: jlwrap
    pyconvert_add_rule("juliacall/ValueBase", Any, pyconvert_rule_jlvalue, 300)
    pyconvert_add_rule("juliacall/As", Any, pyconvert_rule_jlas, 300)
    # priority 200: arrays
    # priority 100: canonical
    pyconvert_add_rule("builtins/NoneType", Nothing, pyconvert_rule_none, 100)
    pyconvert_add_rule("builtins/bool", Bool, pyconvert_rule_bool, 100)
    pyconvert_add_rule("builtins/float", Float64, pyconvert_rule_float, 100)
    pyconvert_add_rule("builtins/complex", Complex{Float64}, pyconvert_rule_complex, 100)
    pyconvert_add_rule("builtins/int", Integer, pyconvert_rule_int, 100)
    pyconvert_add_rule("builtins/str", String, pyconvert_rule_str, 100)
    # priority 0: reasonable
    pyconvert_add_rule("builtins/NoneType", Missing, pyconvert_rule_none)
    pyconvert_add_rule("builtins/bool", Number, pyconvert_rule_bool)
    pyconvert_add_rule("builtins/float", Number, pyconvert_rule_float)
    pyconvert_add_rule("builtins/float", Nothing, pyconvert_rule_float)
    pyconvert_add_rule("builtins/float", Missing, pyconvert_rule_float)
    pyconvert_add_rule("builtins/complex", Number, pyconvert_rule_complex)
    pyconvert_add_rule("builtins/int", Number, pyconvert_rule_int)
    pyconvert_add_rule("builtins/str", Symbol, pyconvert_rule_str)
    pyconvert_add_rule("builtins/str", Char, pyconvert_rule_str)
    # priority -100: fallbacks
    pyconvert_add_rule("builtins/object", Py, pyconvert_rule_object, -100)
    # priority -200: explicit
end
