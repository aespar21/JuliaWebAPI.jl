@compat abstract type AbstractAPIResponder end

immutable APISpec
    fn::Function
    resp_json::Bool
    resp_headers::Dict{String,String}
end

const EndPts = Dict{String,APISpec}

"""
APIResponder holds the transport and format used for data exchange and the endpoint specifications.
"""
immutable APIResponder{T<:AbstractTransport,F<:AbstractMsgFormat}
    transport::T
    format::F
    id::Union{Void,String}  # optional responder id to be sent back
    open::Bool  #whether the responder will process all functions, or only registered ones
    endpoints::EndPts
end

APIResponder{T<:AbstractTransport,F<:AbstractMsgFormat}(transport::T, format::F, id::Union{Void,String}=nothing, open::Bool=false) = APIResponder(transport, format, id, open, EndPts())

"""
APIResponder holds the transport and format used for data exchange and the endpoint specifications.
This method creates an APIResponder over ZMQ transport using JSON message format.
(provided for backward compatibility)
"""
APIResponder(addr::String, ctx::Context=Context(), bound::Bool=true, id=nothing, open=false) = APIResponder(ZMQTransport(addr, REP, bound, ctx), JSONMsgFormat(), id, open, EndPts())
APIResponder(ip::IPv4, port::Int, ctx::Context=Context()) = APIResponder("tcp://$ip:$port", ctx)

function Base.show(io::IO, x::APIResponder)
    println(io, "JuliaWebAPI.APIResponder with endpoints:")
    Base.show_comma_array(STDOUT, keys(x.endpoints), "","")
end

function default_endpoint(f::Function)
    endpt = string(f)
    # separate the module (more natural URL, assumes 'using Module')
    if '.' in endpt
        endpt = rsplit(endpt, '.', limit=2)[2]
    end
    endpt
end

"""
Register a function as API call.
TODO: validate method belongs to module?
"""
function register(conn::APIResponder, f::Function;
                  resp_json::Bool=false,
                  resp_headers::Dict=Dict{String,String}(), endpt=default_endpoint(f))
    Logging.debug("registering endpoint [$endpt]")
    conn.endpoints[endpt] = APISpec(f, resp_json, resp_headers)
    return conn # make fluent api possible
end

"""send a response over the transport in the specified format"""
function respond(conn::APIResponder, code::Int, headers::Dict, resp)
    resp = wireformat(conn.format, code, headers, resp, conn.id)
    sendresp(conn.transport, resp)
end

respond(conn::APIResponder, api::Nullable{APISpec}, status::Symbol, resp=nothing) =
    respond(conn, ERR_CODES[status][1], get_hdrs(api), get_resp(api, status, resp))

get_hdrs(api::Nullable{APISpec}) = !isnull(api) ? get(api).resp_headers : Dict{String,String}()

function get_resp(api::Nullable{APISpec}, status::Symbol, resp=nothing)
    st = ERR_CODES[status]
    stcode = st[2]
    stresp = ((stcode != 0) && (resp === nothing)) ? "$(st[3]) : $(st[2])" : resp

    if !isnull(api) && get(api).resp_json
        return Dict{String, Any}("code"=>stcode, "data"=>stresp)
    else
        return stresp
    end
end

# Note: needs to be changed when https://github.com/JuliaLang/julia/pull/22646 is merged
function dynamic_invoke(conn::APIResponder, f, args...; kwargs...)
    if conn.open && isdefined(Core, :_apply_latest)
        inner() = f(args...; kwargs...)
        Core._apply_latest(inner)
    else
        f(args...; kwargs...)
    end
end

"""call the actual API method, and send the return value back as response"""
function call_api(api::APISpec, conn::APIResponder, args, data::Dict{Symbol,Any})
    try       
        if !applicable(api.fn, args...) || ((api.fn === (*) || api.fn === (/) || api.fn === (\)) && all(x->isa(x,Vector), args))
            narrow_args!(args)
        end
        result = dynamic_invoke(conn, api.fn, args...; data...)
        respond(conn, Nullable(api), :success, result)
    catch ex
        logerr("api_exception: ", ex)
        respond(conn, Nullable(api), :api_exception, string(ex))
    end
end


#=
narrow_args! if a private function that processes an Array transferred
over JSON to a properly typed and dimensioned Julia array. Arrays
serialised from JSON are stored as an Array{Any}, even if all the elements
are members of the same concrete type, eg, Float64. This function will
transform such an array to an Array{Float64} type.

Further, since JSON does not have true multidimensional arrays, they are
transmitted as arrays containing arrays. This function will convert them to
a true multidimensional array in Julia.
=#
promote_arr(x) = Base.collect_to!(similar(x, typeof(x[1])), x, 1, 1)

function narrow_args!(x)
    for (i, v) in enumerate(x)
        if (typeof(v) <: AbstractArray)
            if (length(v) > 0 && typeof(v[1]) <: Array)
                x[i] = hcat(x[i]...)
            end
            x[i] = promote_arr(x[i])
        end
    end
end

"""start processing as a server"""
function process(conn::APIResponder; async::Bool=false)
    if async
        Logging.debug("processing async...")
        @async process(conn)
    else
        Logging.debug("processing...")
        while true
            msg = juliaformat(conn.format, recvreq(conn.transport))

            command = cmd(conn.format, msg)
            Logging.info("received request: ", command)

            if startswith(command, ':')    # is a control command
                ctrlcmd = Symbol(command[2:end])
                if ctrlcmd === :terminate
                    respond(conn, Nullable{APISpec}(), :terminate, "")
                    break
                else
                    err("invalid control command ", command)
                    continue
                end
            end

            if !haskey(conn.endpoints, command)
                if !conn.open || !isdefined(Main, Symbol(command))
                    respond(conn, Nullable{APISpec}(), :invalid_api)
                    continue
                else
                    _add_spec(getfield(Main, Symbol(command)), conn)
                end
            end

            try
                call_api(conn.endpoints[command], conn, args(conn.format, msg), data(conn.format, msg))
            catch ex
                logerr("exception ", ex)
                respond(conn, Nullable(conn.endpoints[command]), :invalid_data)
            end
        end
        close(conn.transport)
        Logging.info("stopped processing.")
    end
    conn
end

function setup_logging(;log_level=INFO, nid::String=get(ENV,"JBAPI_CID",""))
    api_name = get(ENV,"JBAPI_NAME", "noname")
    logfile = "apisrvr_$(api_name)_$(nid).log"
    Logging.configure(level=log_level, filename=logfile)
end

function process_async(apispecs::Array, addr::String=get(ENV,"JBAPI_QUEUE",""); log_level=INFO, bind::Bool=false, nid::String=get(ENV,"JBAPI_CID",""), open::Bool=false)
    Base.depwarn("processs_async is deprecated, use process(conn::APIResponder; async::Bool=true) instead", :process)
    process(apispecs, addr; log_level=log_level, bind=bind, nid=nid, open=open, async=true)
end

function process(apispecs::Array, addr::String=get(ENV,"JBAPI_QUEUE",""); log_level=Logging.LogLevel(get(ENV, "JBAPI_LOGLEVEL", "INFO")),
                bind::Bool=false, nid::String=get(ENV,"JBAPI_CID",""), open::Bool=false, async::Bool=false)
    Base.depwarn("processs(apispecs::Array,...) is deprecated, use process(conn::APIResponder; async::Bool=false) instead", :process)
    setup_logging(;log_level=log_level)
    Logging.debug("queue is at $addr")
    api = create_responder(apispecs, addr, bind, nid, open)
    process(api; async=async)
end

_add_spec(fn::Function, api::APIResponder) = register(api, fn, resp_json=false, resp_headers=Dict{String,String}())

function _add_spec(spec::Tuple, api::APIResponder)
    fn = spec[1]
    resp_json = (length(spec) > 1) ? spec[2] : false
    resp_headers = (length(spec) > 2) ? spec[3] : Dict{String,String}()
    api_name = (length(spec) > 3) ? spec[4] : default_endpoint(fn)
    register(api, fn, resp_json=resp_json, resp_headers=resp_headers, endpt=api_name)
end

function create_responder(apispecs::Array, addr, bind, nid, open=false)
    api = APIResponder(ZMQTransport(addr, REP, bind, Context()), JSONMsgFormat(), nid, open)
    for spec in apispecs
        _add_spec(spec, api)
    end
    api
end

function process()
    Base.depwarn("process() is deprecated, use process(conn::APIResponder; async::Bool=false) instead", :process)
    log_level = Logging.LogLevel(get(ENV, "JBAPI_LOGLEVEL", "INFO"))
    setup_logging(;log_level=log_level)

    Logging.info("Reading api server configuration from environment...")
    Logging.info("JBAPI_NAME=" * get(ENV,"JBAPI_NAME",""))
    Logging.info("JBAPI_QUEUE=" * get(ENV,"JBAPI_QUEUE",""))
    Logging.info("JBAPI_CMD=" * get(ENV,"JBAPI_CMD",""))
    Logging.info("JBAPI_CID=" * get(ENV,"JBAPI_CID",""))
    Logging.info("JBAPI_LOGLEVEL=" * get(ENV,"JBAPI_LOGLEVEL","") * " as " * string(log_level))

    cmd = get(ENV,"JBAPI_CMD","")
    eval(parse(cmd))
    nothing
end

function logerr(msg, ex)
    iob = IOBuffer()
    write(iob, msg)
    showerror(iob, ex)
    err(String(take!(iob)))
end
