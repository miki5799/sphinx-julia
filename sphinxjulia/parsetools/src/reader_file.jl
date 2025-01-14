using ..model

function ismodule(x)
    if typeof(x) != Expr
        return false
    elseif x.head == :module
        return true
    else
        return false
    end
end

function isfunction(x)
    if typeof(x) != Expr
        return false
    elseif x.head == :function
        return true
    elseif x.head == Symbol("=") &&
        typeof(x.args[1]) == Expr &&
        x.args[1].head == :call
        return true
    else
        return false
    end
end

function isdocstring(x)
    if typeof(x) != Expr
        return false
    end
    return x.head == :macrocall &&
        x.args[1] == GlobalRef(Core, Symbol("@doc"))
end

function isfield(x)
    if typeof(x) == Symbol
        return true
    elseif typeof(x) != Expr
        return false
    elseif x.head == Symbol("::")
        return true
    elseif x.head == Symbol("=")
        if typeof(x.args[1]) == Symbol
            return true
        elseif typeof(x.args[1]) == Expr && x.args[1].head == Symbol("::")
            return true
        else
            return false
        end
    else
        return false
    end
end

function extractdocstring(x)
    if isdocstring(x)
        @static if VERSION < v"0.7.0"
            d = string(x.args[2])
            return d, x.args[3]
        else
            d = string(x.args[3])
            return d, x.args[4]
        end
    else
        return "", x
    end
end

function read_argument(arg)
    argumenttype = ""
    value = ""
    macrocall = ""
    if typeof(arg) == Symbol
        name = arg
    elseif typeof(arg) == Expr
        if arg.head == :kw
            keyword = arg.args[1]
            if typeof(keyword) == Symbol
                name = keyword
            else
                @assert keyword.head == Symbol("::")
                if length(keyword.args) == 1
                    name = ""
                    argumenttype = keyword.args[1]
                else
                    @assert length(keyword.args) == 2
                    name = keyword.args[1]
                    argumenttype = keyword.args[2]
                end
            end
            value = arg.args[2]
            # Show string literals in quotes
            if typeof(value) <: AbstractString
                value = repr(value)
            end
        elseif arg.head == Symbol("::")
            if length(arg.args) == 1
                name = ""
                argumenttype = arg.args[1]
            else
                @assert length(arg.args) == 2
                name = arg.args[1]
                argumenttype = arg.args[2]
            end
        elseif arg.head == :macrocall
            @assert length(arg.args) == 3
            macrocall = arg.args[1]
            arg = arg.args[3]
            if typeof(arg) == Symbol
                name = arg
            elseif length(arg.args) == 2
                name = arg.args[1]
                value = arg.args[2]
            else
                error()
            end
        else
            error()
        end
    else
        error()
    end
    model.Argument(string(name), string(argumenttype), string(value), string(macrocall))
end

function read_signature(x::Vector)
    positionalarguments = model.Argument[]
    optionalarguments = model.Argument[]
    keywordarguments = model.Argument[]
    varargs = nothing
    kwvarargs = nothing
    # Read keyword arguments
    if length(x) > 0 && typeof(x[1]) == Expr && x[1].head == :parameters
        @assert x[1].head == :parameters
        for arg in x[1].args
            @assert typeof(arg) == Expr
            if arg.head == Symbol("...")
                kwvarargs = read_argument(arg.args[1])
            else
                push!(keywordarguments, read_argument(arg))
            end
        end
        x = x[2:end]
    end
    # Read positional arguments
    for arg in x
        if typeof(arg) == Expr && arg.head == Symbol("...")
            varargs = read_argument(arg.args[1])
        else
            argument = read_argument(arg)
            if argument.value == ""
                push!(positionalarguments, argument)
            else
                push!(optionalarguments, argument)
            end
        end
    end

    model.Signature(positionalarguments, optionalarguments, keywordarguments,
              varargs, kwvarargs)
end

function read_function(x::Expr, docstring::AbstractString)
    @assert (x.head == :function
                || (x.head == Symbol("=")
                    && typeof(x.args[1]) == Expr
                    && x.args[1].head == :call))
    if typeof(x.args[1]) == Symbol # function f end
        modulename = ""
        name = string(x.args[1])
        templateparameters = AbstractString[]
        signature = read_signature([])
        return model.Function(name, modulename, templateparameters, signature, docstring)
    end
    templateparameters = AbstractString[]
    if x.args[1].head == :(::) # function ...f(...)::Type
        funcexpr = x.args[1].args[1]
        returntype = x.args[1].args[2] # Ignore returntype for now # TODO!
    elseif x.args[1].head == :where # function ...f(...) where {T}
        funcexpr = x.args[1].args[1]
        templateparameters = [string(x) for x=x.args[1].args[2:end]]
    else
        funcexpr = x.args[1]
    end
    definition = funcexpr.args[1]
    if typeof(definition) == Symbol # function f(...)
        name = string(definition)
        modulename = ""
    else
        @assert typeof(definition) == Expr
        if definition.head == :curly # function Base.f{T}(...)
            fullname = definition.args[1]
            templateparameters = [string(x) for x=definition.args[2:end]]
        else # function Base.f(...)
            fullname = definition
        end
        if typeof(fullname) == Symbol # function f(...)
            modulename = ""
            name = string(fullname)
        else # function Base.f(...)
            @assert fullname.head == Symbol(".")
            modulename = string(fullname.args[1])
            name = string(fullname.args[2].value)
        end
    end
    signature = read_signature(funcexpr.args[2:end])
    model.Function(name, modulename, templateparameters, signature, docstring)
end

read_field(x::Symbol) = model.Field(string(x), "", "")

function read_field(x::Expr)
    fieldtype = ""
    value = ""
    if x.head == Symbol("=")
        value = x.args[2]
        x = x.args[1]
    end
    if typeof(x) == Symbol
        name = x
    elseif x.head == Symbol("::")
        name = x.args[1]
        fieldtype = x.args[2]
    else
        error()
    end
    model.Field(string(name), string(fieldtype), string(value))
end

read_typedeclaration(x::Symbol) = (string(x), AbstractString[], "")

function read_typedeclaration(x::Expr)
    templateparameters = AbstractString[]
    supertype = ""
    if x.head == Symbol("<:")
        supertype = string(x.args[2])
        x = x.args[1]
    end
    if typeof(x) == Symbol
        name = x
    elseif x.head == :curly
        name = x.args[1]
        templateparameters = [string(x) for x=x.args[2:end]]
    else
        error()
    end
    return string(name), templateparameters, supertype
end

function read_abstract(x::Expr, docstring::AbstractString)
    @assert x.head == :abstract
    name, templateparameters, supertype = read_typedeclaration(x.args[1])
    return model.Abstract(name, templateparameters, supertype, docstring)
end

function read_type(x::Expr, docstring::AbstractString)
    @assert x.head == :type || x.head == :struct
    name, templateparameters, supertype = read_typedeclaration(x.args[2])
    fields = model.Field[]
    constructors = model.Function[]
    @assert length(x.args) == 3
    @assert x.args[3].head == :block
    for arg in x.args[3].args
        innerdocstring, arg = extractdocstring(arg)
        # XXX: Julia's AST parser (as of v0.6) does not correctly parse
        # docstrings associated with type constructors. In practice, Julia's
        # 'help' tool will show type-level documentation when trying to lookup
        # a constructor. The work-around below does essentially the same thing
        # in the documentation by copying the type's docstring into the
        # constructor.
        if isempty(innerdocstring)
            innerdocstring = docstring
        end
        if typeof(arg) != Expr
            continue
        elseif isfield(arg)
            push!(fields, read_field(arg))
        elseif isfunction(arg)
            func = read_function(arg, innerdocstring)
            if func.name == name
                push!(constructors, func)
            end
        elseif false
            # Not supported yet
        elseif arg.head == :let || arg.head == :macrocall || arg.head == :line
            # Won't support
        else
            dump(arg)
            error()
        end
    end
    return model.CompositeType(name, templateparameters, supertype, fields, constructors, docstring)
end

function read_module(x::Expr, docstring::AbstractString)
    @assert x.head == :module
    name = string(x.args[2])
    body = Union{model.Module, model.Abstract, model.CompositeType, model.Function}[]
    @assert length(x.args) == 3
    @assert typeof(x.args[3]) == Expr
    @assert x.args[3].head == :block
    for arg in x.args[3].args
        innerdocstring, arg = extractdocstring(arg)
        if typeof(arg) != Expr
            continue
        end
        if arg.head == :abstract
            push!(body, read_abstract(arg, innerdocstring))
        elseif arg.head == :type || arg.head == :struct
            push!(body, read_type(arg, innerdocstring))
        elseif isfunction(arg)
            func = read_function(arg, innerdocstring)
            if func.name == "eval"
                continue
            end
            push!(body, func)
        elseif ismodule(arg)
            push!(body, read_module(arg, innerdocstring))
        elseif arg.head == :toplevel || arg.head == :typealias ||
               arg.head == :macro || arg.head == :const || arg.head == :importall ||
               arg.head == :export || arg.head == :import || arg.head == :global ||
               arg.head == :using || arg.head == :bitstype || arg.head == Symbol(".")
            # Not supported yet
        elseif arg.head == :macrocall || arg.head == :call ||
               arg.head == :for || arg.head == :let || arg.head == :if ||
               arg.head == :try || arg.head == Symbol("=") || arg.head == :ccall ||
               arg.head == Symbol("&&") || arg.head == :quote || arg.head == :line
            # Won't support
        else
            println(arg)
            println(arg.head)
            error()
        end
    end
    model.Module(name, body, docstring)
end

function read_file(sourcepath)
    f = open(sourcepath)
    @static if VERSION < v"0.7.0"
        buf = readstring(f)
    else
        try 
            buf = read_and_include_files(sourcepath)
        catch e
            println("Error reading file: $sourcepath \n $e \n Continuing read without includes.")
            buf = read(f, String)
        end
    end
    close(f)
    buf = "module __temp__\n $(buf)\nend"
    ast = Meta.parse(buf)
    m = read_module(ast, "")
    # if length(m.body) == 1 && typeof(m.body[1]) == model.Module
    #     return m.body[1]
    # else
        m.name = ""
        return m
    # end
end

function read_and_include_files(file_path::String, base_path::String="")
    # Determine the base path for relative includes
    if base_path == ""
        base_path = dirname(file_path)
    end
    
    # Initialize an empty string to accumulate file contents
    total_content = ""
    
    # Open and read the file
    open(file_path, "r") do file
        for line in eachline(file)
            # Check if the line contains an include statement
            trimmed_line = strip(line)
            if startswith(trimmed_line, "include(") && endswith(trimmed_line, ")")
                # Extract the included file path
                include_path = strip(trimmed_line[9:end-1], ['"', '\''])
                
                # Build the full path for the included file
                full_include_path = ispath(include_path) ? include_path : joinpath(base_path, include_path)
                
                # Recursively read and include files
                included_content = read_and_include_files(full_include_path, base_path)
                total_content *= included_content
            else
                # Append the current line to the total content
                total_content *= line * "\n"
            end
        end
    end
    
    return total_content
end

