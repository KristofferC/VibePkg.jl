# Compatibility namespace for the legacy Pkg.BinaryPlatforms wrapper API.
# Platform parsing and comparison remain owned by Base.BinaryPlatforms; this
# module only supplies the old constructor types and Symbol-valued accessors.
module BinaryPlatformsCompat

    export platform_key_abi, platform_dlext, valid_dl_path, arch, libc,
        libgfortran_version, libstdcxx_version, cxxstring_abi,
        parse_dl_name_version, detect_libgfortran_version,
        detect_libstdcxx_version, detect_cxxstring_abi, call_abi, wordsize,
        triplet, select_platform, platforms_match, CompilerABI, Platform,
        UnknownPlatform, Linux, MacOS, Windows, FreeBSD

    using Base.BinaryPlatforms: parse_dl_name_version,
        detect_libgfortran_version, detect_libstdcxx_version,
        detect_cxxstring_abi, os, call_abi, select_platform, platforms_match,
        AbstractPlatform, Platform, HostPlatform

    import Base.BinaryPlatforms: libgfortran_version, libstdcxx_version,
        platform_name, wordsize, platform_dlext, tags, arch, libc, call_abi,
        cxxstring_abi

    struct UnknownPlatform <: AbstractPlatform
        UnknownPlatform(args...; kwargs...) = new()
    end
    tags(::UnknownPlatform) = Dict{String, String}("os" => "unknown")

    struct CompilerABI
        libgfortran_version::Union{Nothing, VersionNumber}
        libstdcxx_version::Union{Nothing, VersionNumber}
        cxxstring_abi::Union{Nothing, Symbol}

        function CompilerABI(;
                libgfortran_version::Union{Nothing, VersionNumber} = nothing,
                libstdcxx_version::Union{Nothing, VersionNumber} = nothing,
                cxxstring_abi::Union{Nothing, Symbol} = nothing,
            )
            return new(libgfortran_version, libstdcxx_version, cxxstring_abi)
        end
    end

    function CompilerABI(
            cabi::CompilerABI;
            libgfortran_version = nothing,
            libstdcxx_version = nothing,
            cxxstring_abi = nothing,
        )
        return CompilerABI(;
            libgfortran_version = something(
                libgfortran_version, Some(cabi.libgfortran_version),
            ),
            libstdcxx_version = something(
                libstdcxx_version, Some(cabi.libstdcxx_version),
            ),
            cxxstring_abi = something(cxxstring_abi, Some(cabi.cxxstring_abi)),
        )
    end

    libgfortran_version(cabi::CompilerABI) = cabi.libgfortran_version
    libstdcxx_version(cabi::CompilerABI) = cabi.libstdcxx_version
    cxxstring_abi(cabi::CompilerABI) = cabi.cxxstring_abi

    for T in (:Linux, :Windows, :MacOS, :FreeBSD)
        @eval begin
            struct $(T) <: AbstractPlatform
                p::Platform

                function $(T)(arch::Symbol; compiler_abi = nothing, kwargs...)
                    if compiler_abi !== nothing
                        kwargs = (;
                            kwargs...,
                            :libgfortran_version => libgfortran_version(compiler_abi),
                            :libstdcxx_version => libstdcxx_version(compiler_abi),
                            :cxxstring_abi => cxxstring_abi(compiler_abi),
                        )
                    end
                    return new(
                        Platform(
                            string(arch), $(string(T)); kwargs..., validate_strict = true,
                        )
                    )
                end
            end
        end
    end

    const PlatformUnion = Union{Linux, MacOS, Windows, FreeBSD}

    for f in (:arch, :libc, :call_abi, :cxxstring_abi)
        @eval function $(f)(platform::PlatformUnion)
            value = $(f)(platform.p)
            return value === nothing ? nothing : Symbol(value)
        end
    end

    for f in (
            :libgfortran_version, :libstdcxx_version, :platform_name, :wordsize,
            :platform_dlext, :tags, :triplet,
        )
        @eval $(f)(platform::PlatformUnion) = $(f)(platform.p)
    end

    Base.:(==)(a::PlatformUnion, b::AbstractPlatform) = b == a.p

    MacOS(; kwargs...) = MacOS(:x86_64; kwargs...)
    FreeBSD(; kwargs...) = FreeBSD(:x86_64; kwargs...)

    function triplet(platform::AbstractPlatform)
        # Preserve the historical Pkg wrapper's fixed OS-version components.
        if Sys.isfreebsd(platform)
            platform = deepcopy(platform)
            platform["os_version"] = "11.1.0"
        elseif Sys.isapple(platform)
            platform = deepcopy(platform)
            platform["os_version"] = "14.0.0"
        end
        return Base.BinaryPlatforms.triplet(platform)
    end

    platform_key_abi() = HostPlatform()
    platform_key_abi(value::AbstractString) = parse(Platform, value)

    function valid_dl_path(path::AbstractString, platform::AbstractPlatform)
        try
            parse_dl_name_version(path, string(os(platform))::String)
            return true
        catch err
            err isa ArgumentError || rethrow()
            return false
        end
    end

end # module BinaryPlatformsCompat

const BinaryPlatforms = BinaryPlatformsCompat
