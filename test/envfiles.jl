# depot isolation + hermeticity guard for the whole process
# (see test/local_pkg_server.jl — never touches ~/.julia)
if !@isdefined(LocalPkgServer)
    include("local_pkg_server.jl")
end
LocalPkgServer.isolate!()

using Test
using UUIDs: UUID
using TOML
using VibePkg
using VibePkg.EnvFiles
using VibePkg.EnvFiles: with_project, with_manifest, Compat, SourceSpec, AppInfo,
    PathTracked, RepoTracked, RegistryTracked
using VibePkg.Errors: PkgError
using VibePkg.Versions: semver_spec

@testset "app metadata validation" begin
    valid = VibePkg.EnvFiles.read_project_apps(
        Dict{String, Any}(
            "hello-world" => Dict{String, Any}("submodule" => "CLI"),
        )
    )
    @test valid["hello-world"].submodule == "CLI"

    for name in ("", "../outside", "dir/app", raw"dir\app", "-leading")
        @test_throws PkgError VibePkg.EnvFiles.read_project_apps(
            Dict{String, Any}(name => Dict{String, Any}())
        )
    end
    @test_throws PkgError VibePkg.EnvFiles.read_project_apps(
        Dict{String, Any}("hello" => Dict{String, Any}("submodule" => "CLI.Sub"))
    )
    @test_throws PkgError VibePkg.EnvFiles.read_project_apps(
        Dict{String, Any}("hello" => Dict{String, Any}("submodule" => 1))
    )

    # Stored app entries use a qualified module name, but retain the same
    # path-safe app-name contract.
    manifest_app = Dict{String, Any}(
        "julia_command" => joinpath(Sys.BINDIR, "julia"),
        "submodule" => "AppPkg.CLI",
    )
    @test VibePkg.EnvFiles.read_apps(Dict("hello" => manifest_app))["hello"].submodule == "AppPkg.CLI"
    @test_throws PkgError VibePkg.EnvFiles.read_apps(Dict("../outside" => manifest_app))
end

const MANIFEST_FIXTURES = joinpath(@__DIR__, "fixtures", "manifest")

manifest_body(text) = split(text, "\n\n"; limit = 2)[2]  # strip header comment

@testset "EnvFiles" begin

    @testset "project round trip" begin
        raw = """
        name = "Example"
        uuid = "7876af07-990d-54b4-ab0e-23690620f79a"
        version = "1.2.3"
        custom_key = "preserved"

        [deps]
        TOML = "fa267f1f-6049-4f14-aa54-33bafae1ed76"
        Example = "0000af07-990d-54b4-ab0e-23690620f79a"

        [weakdeps]
        SHA = "ea8e919c-243c-51af-8825-aaa63cd721ce"

        [extensions]
        SHAExt = "SHA"

        [sources]
        Example = { url = "https://example.com/Example.jl", rev = "main" }

        [compat]
        julia = "1.12"
        TOML = "1"

        [extras]
        Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"

        [targets]
        test = ["Test"]
        """
        p = parse_project(TOML.parse(raw))
        @test p.name == "Example"
        @test p.uuid == UUID("7876af07-990d-54b4-ab0e-23690620f79a")
        @test p.version == v"1.2.3"
        @test p.sources["Example"] == SourceSpec(nothing, "https://example.com/Example.jl", "main", nothing)
        @test p.compat["TOML"].val == semver_spec("1")
        @test p.raw["custom_key"] == "preserved"

        text = render_project(p)
        @test parse_project(TOML.parse(text)) == p
        @test occursin("custom_key = \"preserved\"", text)
        lines = split(text, '\n')
        @test startswith(lines[1], "name = ")     # canonical key order
        @test startswith(lines[2], "uuid = ")
        @test occursin(r"Example = \{.*url = ", text)  # sources inline

        # functional update leaves the original untouched
        p2 = with_project(p; version = v"2.0.0")
        @test p2.version == v"2.0.0" && p.version == v"1.2.3" && p2 != p
    end

    @testset "project semantics" begin
        # deps ∩ weakdeps: weak-only in memory, merged back into [deps] on write
        p = parse_project(
            TOML.parse(
                """
                [deps]
                SHA = "ea8e919c-243c-51af-8825-aaa63cd721ce"
                [weakdeps]
                SHA = "ea8e919c-243c-51af-8825-aaa63cd721ce"
                """
            )
        )
        @test !haskey(p.deps, "SHA") && haskey(p.deps_weak, "SHA")
        out = TOML.parse(render_project(p))
        @test haskey(out["deps"], "SHA") && haskey(out["weakdeps"], "SHA")

        # legacy `path` key becomes entryfile; only entryfile is written back
        p = parse_project(TOML.parse("path = \"src/other.jl\""))
        @test p.entryfile == "src/other.jl"
        out = TOML.parse(render_project(p))
        @test out["entryfile"] == "src/other.jl" && !haskey(out, "path")

        # a few validation errors
        @test_throws PkgError parse_project(
            TOML.parse(
                """
                [deps]
                A = "ea8e919c-243c-51af-8825-aaa63cd721ce"
                B = "ea8e919c-243c-51af-8825-aaa63cd721ce"
                """
            )
        )
        @test_throws PkgError parse_project(TOML.parse("[compat]\nNotADep = \"1\""))
        @test_throws PkgError parse_project(
            TOML.parse(
                """
                [deps]
                A = "ea8e919c-243c-51af-8825-aaa63cd721ce"
                [sources]
                A = { url = "https://example.com", path = "../A" }
                """
            )
        )
    end

    @testset "manifest read + round trip" begin
        m = read_manifest(joinpath(MANIFEST_FIXTURES, "good", "simple.toml"))
        @test m.manifest_format == v"2.0.0"
        example = only(e for (u, e) in m if e.name == "Example")
        @test example.tracking isa RegistryTracked
        @test entry_version(example) == v"0.5.1"
        @test haskey(example.deps, "Test")
        stdlib = only(e for (u, e) in m if e.name == "Base64")
        @test entry_version(stdlib) === nothing && entry_tree_hash(stdlib) === nothing

        text = render_manifest(m)
        @test startswith(text, "# This file is machine-generated - editing it directly is not advised\n\n")
        @test parse_manifest(TOML.parse(manifest_body(text)), "roundtrip") == m

        # duplicate names round trip through the uuid-table deps form
        m = read_manifest(joinpath(MANIFEST_FIXTURES, "good", "not_unique_names.toml"))
        @test parse_manifest(TOML.parse(manifest_body(render_manifest(m))), "roundtrip") == m
    end

    @testset "manifest deps normalization" begin
        # Pkg.jl#4631: vector-form deps may name a stdlib without a manifest
        # entry of its own; it maps to the stdlib uuid
        text = """
        manifest_format = "2.0"

        [[deps.Example]]
        deps = ["SHA"]
        git-tree-sha1 = "1111111111111111111111111111111111111111"
        uuid = "7876af07-990d-54b4-ab0e-23690620f79a"
        version = "0.5.1"
        """
        m = parse_manifest(TOML.parse(text), "test")
        example = m[UUID("7876af07-990d-54b4-ab0e-23690620f79a")]
        @test example.deps["SHA"] == UUID("ea8e919c-243c-51af-8825-aaa63cd721ce")
        # a missing non-stdlib name still errors
        @test_throws PkgError parse_manifest(TOML.parse(replace(text, "SHA" => "NotAThing")), "test")

        # Pkg.jl#128: the short name-array deps form is only used when the
        # recorded uuid matches the manifest entry of that name
        text = """
        manifest_format = "2.0"

        [[deps.A]]
        git-tree-sha1 = "1111111111111111111111111111111111111111"
        uuid = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        version = "1.0.0"

            [deps.A.weakdeps]
            B = "cccccccc-cccc-cccc-cccc-cccccccccccc"

        [[deps.B]]
        git-tree-sha1 = "2222222222222222222222222222222222222222"
        uuid = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
        version = "1.0.0"
        """
        m = parse_manifest(TOML.parse(text), "test")
        m2 = parse_manifest(TOML.parse(manifest_body(render_manifest(m))), "roundtrip")
        @test m2[UUID("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")].weakdeps["B"] ==
            UUID("cccccccc-cccc-cccc-cccc-cccccccccccc")
    end

    @testset "safe_realpath termination" begin
        # Pkg.jl#3085: nonexistent, empty, and drive-like paths return without error
        sr = VibePkg.Environments.safe_realpath
        # Start below a canonical, platform-native root.  On Windows,
        # `/no-such-root` is relative to the current drive and realpath(`/`)
        # legitimately expands it to (for example) `D:\\`.
        deep = joinpath(realpath(tempdir()), "vibepkg-no-such-root", fill("x", 30)...)
        @test sr(deep) == deep
        @test sr("") == ""
        @test sr("Z:") == "Z:"
    end

    @testset "manifest entry states" begin
        uuid = UUID("11111111-2222-3333-4444-555555555555")
        sha = Base.SHA1("8eb7b4d4ca487caade9ba3e85932e28ce6d6e1f8")
        mk(tracking; pinned = false) = with_manifest(
            Manifest();
            julia_version = v"1.12.0",
            deps = Dict(
                uuid => EnvFiles.ManifestEntry(
                    "Foo", uuid, tracking, pinned,
                    Dict{String, UUID}(), Dict{String, UUID}(),
                    Dict{String, Union{String, Vector{String}}}(), Dict{String, AppInfo}(),
                    nothing, nothing, Dict{String, Any}(),
                )
            ),
        )
        entry_toml(m) = TOML.parse(manifest_body(render_manifest(m)))["deps"]["Foo"][1]

        e = entry_toml(mk(RegistryTracked(v"1.0.0", sha, ["General"])))
        @test e["version"] == "1.0.0" && e["git-tree-sha1"] == string(sha)
        @test e["registries"] == "General"          # single registry as bare string

        e = entry_toml(mk(PathTracked("../Foo", v"1.0.0")))
        @test e["path"] == "../Foo" && !haskey(e, "git-tree-sha1")

        e = entry_toml(mk(RepoTracked("https://x.com/Foo.jl", "main", nothing, sha, v"1.0.0")))
        @test e["repo-url"] == "https://x.com/Foo.jl" && e["repo-rev"] == "main"

        e = entry_toml(mk(RegistryTracked(v"1.0.0", sha, String[]); pinned = true))
        @test e["pinned"] === true

        # repo tracking without a tree hash cannot be written
        @test_throws PkgError render_manifest(mk(RepoTracked("https://x.com/Foo.jl", "main", nothing, nothing, nothing)))
    end

    @testset "manifest metadata" begin
        text = """
        julia_version = "1.12.0"
        manifest_format = "2.1"
        project_hash = "8eb7b4d4ca487caade9ba3e85932e28ce6d6e1f8"

        [[deps.Example]]
        entryfile = "src/other.jl"
        git-tree-sha1 = "8eb7b4d4ca487caade9ba3e85932e28ce6d6e1f8"
        uuid = "7876af07-990d-54b4-ab0e-23690620f79a"
        version = "0.5.1"
        """
        m = parse_manifest(TOML.parse(text), "test")
        # project_hash is a single typed channel
        @test m.project_hash == Base.SHA1("8eb7b4d4ca487caade9ba3e85932e28ce6d6e1f8")
        @test !haskey(m.raw, "project_hash")
        m2 = with_manifest(m; project_hash = Base.SHA1("0000000000000000000000000000000000000000"))
        @test occursin("project_hash = \"0000000000000000000000000000000000000000\"", render_manifest(m2))
        # entryfile round-trips
        @test m[UUID("7876af07-990d-54b4-ab0e-23690620f79a")].entryfile == "src/other.jl"
        @test occursin("entryfile = \"src/other.jl\"", render_manifest(m))
    end

    @testset "JuliaProject.toml discovery" begin
        # JuliaProject.toml is preferred over Project.toml (Base.project_names order)
        mktempdir() do dir
            write(joinpath(dir, "Project.toml"), "name = \"Plain\"\n")
            write(joinpath(dir, "JuliaProject.toml"), "name = \"JuliaFlavored\"\n")
            @test projectfile_path(dir) == joinpath(dir, "JuliaProject.toml")
            # non-strict manifest pairing follows the project file flavor
            @test manifestfile_path(dir) == joinpath(dir, "JuliaManifest.toml")

            env = VibePkg.Environments.load_environment(dir; depots = VibePkg.Depots.depot_stack())
            @test basename(env.project_file) == "JuliaProject.toml"
            @test env.project.name == "JuliaFlavored"
            @test basename(env.manifest_file) == "JuliaManifest.toml"
        end
        # without JuliaProject.toml, the plain names are used
        mktempdir() do dir
            write(joinpath(dir, "Project.toml"), "name = \"Plain\"\n")
            @test projectfile_path(dir) == joinpath(dir, "Project.toml")
            @test manifestfile_path(dir) == joinpath(dir, "Manifest.toml")
        end
    end

    @testset "versioned manifest discovery" begin
        mktempdir() do dir
            vname = "Manifest-v$(VERSION.major).$(VERSION.minor).toml"
            write(joinpath(dir, "Project.toml"), "")
            versioned = joinpath(dir, vname)
            write(
                versioned, """
                julia_version = "$(VERSION.major).$(VERSION.minor).0"
                manifest_format = "2.0"

                [[deps.Example]]
                git-tree-sha1 = "1111111111111111111111111111111111111111"
                uuid = "7876af07-990d-54b4-ab0e-23690620f79a"
                version = "0.5.0"
                """
            )
            plain = joinpath(dir, "Manifest.toml")
            write(plain, "julia_version = \"1.0.0\"\nmanifest_format = \"2.0\"\n")
            plain_bytes = read(plain)

            @test manifestfile_path(dir) == versioned

            depots = VibePkg.Depots.depot_stack()
            env = VibePkg.Environments.load_environment(dir; depots)
            @test basename(env.manifest_file) == vname
            @test haskey(env.manifest, UUID("7876af07-990d-54b4-ab0e-23690620f79a"))

            # a write goes through the versioned file; the plain one is untouched
            m2 = with_manifest(env.manifest; julia_version = v"1.99.0")
            env2 = VibePkg.Environments.Environment(
                env.project_file, env.manifest_file, env.project, m2, env.workspace
            )
            @test VibePkg.Environments.write_environment(env, env2)
            @test occursin("julia_version = \"1.99.0\"", read(versioned, String))
            @test read_manifest(versioned).julia_version == v"1.99.0"
            @test read(plain) == plain_bytes
        end
    end

    @testset "manifest [registries] round trip" begin
        text = """
        julia_version = "1.12.0"
        manifest_format = "2.1"

        [registries.General]
        uuid = "23338594-aafe-5451-b93e-139f81909106"
        url = "https://github.com/JuliaRegistries/General.git"

        [registries.Local]
        uuid = "23338594-aafe-5451-b93e-139f81909107"

        [[deps.Example]]
        git-tree-sha1 = "1111111111111111111111111111111111111111"
        uuid = "7876af07-990d-54b4-ab0e-23690620f79a"
        version = "0.5.0"
        """
        m = parse_manifest(TOML.parse(text), "test")
        general = m.registries["General"]
        @test general.uuid == UUID("23338594-aafe-5451-b93e-139f81909106")
        @test general.url == "https://github.com/JuliaRegistries/General.git"
        local_reg = m.registries["Local"]
        @test local_reg.uuid == UUID("23338594-aafe-5451-b93e-139f81909107")
        @test local_reg.url === nothing    # url is optional

        # read → write survives unchanged, `url` omitted when absent
        rendered = render_manifest(m)
        @test parse_manifest(TOML.parse(manifest_body(rendered)), "roundtrip") == m
        raw = TOML.parse(manifest_body(rendered))
        @test raw["registries"]["General"]["url"] == "https://github.com/JuliaRegistries/General.git"
        @test !haskey(raw["registries"]["Local"], "url")

        # a nonempty [registries] section requires format 2.1 on write
        m20 = with_manifest(m; manifest_format = v"2.0.0")
        @test TOML.parse(manifest_body(render_manifest(m20)))["manifest_format"] == "2.1"

        # empty registries: the section is omitted entirely
        m_empty = with_manifest(m; registries = Dict{String, EnvFiles.RegistryRef}())
        @test !haskey(TOML.parse(manifest_body(render_manifest(m_empty))), "registries")

        # `uuid` is required
        @test_throws PkgError parse_manifest(
            TOML.parse("manifest_format = \"2.1\"\n\n[registries.General]\nurl = \"https://x.com\"\n"),
            "test",
        )
    end

    @testset "manifest formats" begin
        # v1 stays v1 on plain write, without v2 metadata
        m = read_manifest(joinpath(MANIFEST_FIXTURES, "formats", "v1.0", "Manifest.toml"))
        @test m.manifest_format == v"1.0.0"
        raw = TOML.parse(manifest_body(render_manifest(m)))
        @test !haskey(raw, "manifest_format") && !haskey(raw, "julia_version")

        # missing and empty files
        @test read_manifest(joinpath(@__DIR__, "does-not-exist", "Manifest.toml")) == Manifest()
        mktempdir() do dir
            f = joinpath(dir, "Manifest.toml")
            write(f, "")
            @test read_manifest(f).manifest_format == v"2.0.0"
        end

        # malformed manifests error
        for f in readdir(joinpath(MANIFEST_FIXTURES, "bad"); join = true)
            # a stdlib dep without its own entry is valid since Pkg.jl#4631
            basename(f) == "missing_entry.toml" && continue
            @test_throws Exception read_manifest(f)
        end
    end
end

# Malformed TOML values must error via PkgError (or be accepted when valid),
# never silently convert or crash with a MethodError/TypeError.
@testset "malformed TOML scalar and array values" begin
    E = VibePkg.EnvFiles
    # UUID(::Integer) exists, so an integer dep value must error, not convert
    @test_throws PkgError E.read_project_deps(Dict{String, Any}("Foo" => 123), "deps")
    @test_throws PkgError E.read_deps(Dict{String, Any}("Foo" => 123))

    # empty TOML arrays parse as Vector{Any} but are valid dependency lists
    @test E.read_project_targets(Dict{String, Any}("test" => Any[])) == Dict("test" => String[])
    @test E.read_project_exts(Dict{String, Any}("Ext" => Any[])) == Dict("Ext" => String[])
    @test E.read_exts(Dict{String, Any}("Ext" => Any[])) == Dict("Ext" => String[])

    # ... including inside manifest entries (VibePkg itself can write these)
    manifest = """
    manifest_format = "2.0"

    [[deps.Foo]]
    uuid = "7876af07-990d-54b4-ab0e-23690620f79a"
    version = "1.0.0"
    registries = []
    deps = []
    """
    m = read_manifest(IOBuffer(manifest))
    @test haskey(m, UUID("7876af07-990d-54b4-ab0e-23690620f79a"))

    project_file = "/tmp/audited/Project.toml"
    source_err = try
        E.parse_project(
            Dict{String, Any}(
                "sources" => Dict{String, Any}(
                    "Foo" => Dict{String, Any}("path" => 1),
                ),
            );
            file = project_file,
        )
        nothing
    catch err
        err
    end
    @test source_err isa PkgError
    source_message = sprint(showerror, source_err)
    @test occursin(project_file, source_message)
    @test occursin("[sources]", source_message)
    @test occursin("path", source_message)
    @test occursin("1", source_message)

    compat_err = try
        E.parse_project(
            Dict{String, Any}("compat" => Dict{String, Any}("Foo" => 1));
            file = project_file,
        )
        nothing
    catch err
        err
    end
    @test compat_err isa PkgError
    compat_message = sprint(showerror, compat_err)
    @test occursin(project_file, compat_message)
    @test occursin("[compat]", compat_message)
    @test occursin("Foo", compat_message)

    manifest_err = try
        E.parse_manifest(
            Dict{String, Any}("manifest_format" => "2.0", "deps" => "not-a-table"),
            IOBuffer(),
        )
        nothing
    catch err
        err
    end
    @test manifest_err isa PkgError
    manifest_message = sprint(showerror, manifest_err)
    @test occursin("deps", lowercase(manifest_message))
    @test occursin("table", lowercase(manifest_message))
end

# Pkg.jl manifests.jl "v3.0: unknown format, warn" — a manifest declaring a
# major format outside 1:2 still parses, but warns that behavior is undefined.
@testset "unknown manifest format warns" begin
    text = """
    julia_version = "$(VERSION)"
    manifest_format = "3.0"

    [[deps.Example]]
    git-tree-sha1 = "1111111111111111111111111111111111111111"
    uuid = "7876af07-990d-54b4-ab0e-23690620f79a"
    version = "0.5.1"
    """
    # use the IO form so the warning isn't maxlog-suppressed across runs
    local m
    @test_logs (:warn,) match_mode = :any begin
        m = parse_manifest(TOML.parse(text), IOBuffer())
    end
    @test haskey(m, UUID("7876af07-990d-54b4-ab0e-23690620f79a"))
end

# Pkg.jl manifests.jl "instantiate manifest from different julia_version" /
# "manifest from a different julia minor version" — the manifest's recorded
# julia version is checked against the running one: a mismatch (or a missing
# entry / pre-v2 format) warns by default and errors under
# julia_version_strict; a matching minor is silent; an empty manifest is exempt.
@testset "manifest julia_version compatibility" begin
    body(jv) = """
    julia_version = "$jv"
    manifest_format = "2.0"

    [[deps.Example]]
    git-tree-sha1 = "1111111111111111111111111111111111111111"
    uuid = "7876af07-990d-54b4-ab0e-23690620f79a"
    version = "0.5.1"
    """
    mk(text) = parse_manifest(TOML.parse(text), "jvtest")
    cur = VersionNumber(VERSION.major, VERSION.minor, 0)
    other = VersionNumber(VERSION.major, VERSION.minor == 0 ? 99 : VERSION.minor - 1, 0)

    # matching minor: no warning, no error
    @test_logs check_manifest_julia_version_compat(mk(body(cur)), "f") === nothing

    # different minor: warns by default, errors when strict
    m_diff = mk(body(other))
    @test_logs (:warn,) match_mode = :any check_manifest_julia_version_compat(m_diff, "f")
    @test_throws PkgError check_manifest_julia_version_compat(m_diff, "f"; julia_version_strict = true)

    # missing julia_version entry: same warn / strict-error split
    m_nojv = mk(replace(body(cur), "julia_version = \"$cur\"\n" => ""))
    @test_logs (:warn,) match_mode = :any check_manifest_julia_version_compat(m_nojv, "f")
    @test_throws PkgError check_manifest_julia_version_compat(m_nojv, "f"; julia_version_strict = true)

    # a manifest with no deps is never flagged
    @test check_manifest_julia_version_compat(Manifest(), "f") === nothing
end

# Pkg.jl#4091 — an empty/`touch`ed Manifest.toml is treated as the current (v2)
# format, so activating and adding to it doesn't choke on a missing format line.
@testset "empty manifest reads as v2 format" begin
    mktempdir() do dir
        mf = joinpath(dir, "Manifest.toml")
        touch(mf)
        m = read_manifest(mf)
        @test m.manifest_format == v"2.0.0"
        @test isempty(m.deps)
    end
end

# Pkg.jl#3520 — a manifest's per-dependency `syntax.julia_version` (Julia 1.13+)
# is parsed and round-trips through render.
@testset "per-dep syntax.julia_version round trip" begin
    m = read_manifest(joinpath(MANIFEST_FIXTURES, "good", "withversion.toml"))
    d1 = UUID("f08855a0-36cb-4a32-8ae5-a227b709c612")
    d2 = UUID("e127e659-a899-4a00-b565-5b74face18ba")
    @test m[d1].julia_syntax_version == v"1.13.0"
    @test m[d2].julia_syntax_version == v"1.14.0"
    rt = parse_manifest(TOML.parse(manifest_body(render_manifest(m))), "roundtrip")
    @test rt == m
    @test rt[d1].julia_syntax_version == v"1.13.0"
end

# Project [apps] must serialize from the typed field: a functional update
# (add/remove/change) must reach the written file instead of the stale raw
# table surviving unchanged.
@testset "project [apps] serialization from typed field" begin
    raw = """
    name = "AppPkg"
    uuid = "7876af07-990d-54b4-ab0e-23690620f79a"

    [apps.main]
    submodule = "CLI"
    julia_flags = ["--threads=2"]
    custom_key = "kept"

    [apps.plain]
    """
    p = parse_project(TOML.parse(raw))
    out = TOML.parse(render_project(p))
    @test out["apps"]["main"]["submodule"] == "CLI"
    @test out["apps"]["main"]["julia_flags"] == ["--threads=2"]
    @test out["apps"]["main"]["custom_key"] == "kept"   # unknown keys survive
    @test haskey(out["apps"], "plain")
    @test parse_project(TOML.parse(render_project(p))) == p

    # removing an app through a functional update removes it on write
    p2 = with_project(p; apps = Dict("main" => p.apps["main"]))
    @test !haskey(TOML.parse(render_project(p2))["apps"], "plain")

    # a freshly added app is written
    extra = AppInfo("extra", nothing, "Sub", ["--startup-file=no"], Dict{String, Any}())
    p3 = with_project(p; apps = merge(p.apps, Dict("extra" => extra)))
    out3 = TOML.parse(render_project(p3))["apps"]["extra"]
    @test out3["submodule"] == "Sub" && out3["julia_flags"] == ["--startup-file=no"]

    # clearing every app drops the section entirely
    p4 = with_project(p; apps = Dict{String, AppInfo}())
    @test !haskey(TOML.parse(render_project(p4)), "apps")

    # cleared typed fields disappear from the app's raw table too
    changed = AppInfo("main", nothing, nothing, String[], p.apps["main"].raw)
    p5 = with_project(p; apps = Dict("main" => changed, "plain" => p.apps["plain"]))
    out5 = TOML.parse(render_project(p5))["apps"]["main"]
    @test !haskey(out5, "submodule") && !haskey(out5, "julia_flags")
    @test out5["custom_key"] == "kept"
end

# workspace `projects` straight from TOML must be validated as a vector of
# strings before being iterated (a scalar or non-string entry is a user
# error, not a crash)
@testset "workspace projects validation" begin
    @test parse_project(TOML.parse("[workspace]\nprojects = [\"sub\"]")).workspace["projects"] == ["sub"]
    # empty TOML arrays parse as Vector{Any} but are valid
    @test isempty(parse_project(TOML.parse("[workspace]\nprojects = []")).workspace["projects"])
    @test_throws PkgError parse_project(TOML.parse("[workspace]\nprojects = \"sub\""))
    @test_throws PkgError parse_project(TOML.parse("[workspace]\nprojects = 1"))
    @test_throws PkgError parse_project(TOML.parse("[workspace]\nprojects = [1, \"sub\"]"))
    @test_throws PkgError parse_project(TOML.parse("[workspace]\nother = [\"x\"]"))
end

# a symlinked Project.toml keeps the environment's identity at the link:
# only the parent directory is canonicalized, so the manifest lands beside
# the link rather than beside its target
@testset "find_project_file preserves a project-file symlink" begin
    if !Sys.iswindows()     # symlink creation may need privileges on Windows
        mktempdir() do dir
            target_dir = mkpath(joinpath(dir, "target"))
            target = joinpath(target_dir, "Project.toml")
            write(target, "name = \"Linked\"\n")
            envdir = mkpath(joinpath(dir, "env"))
            link = joinpath(envdir, "Project.toml")
            symlink(target, link)

            pf = VibePkg.Environments.find_project_file(link)
            @test pf == joinpath(realpath(envdir), "Project.toml")
            @test islink(pf)
            # the directory form resolves to the same place
            @test VibePkg.Environments.find_project_file(envdir) == pf

            env = VibePkg.Environments.load_environment(envdir; depots = VibePkg.Depots.depot_stack())
            @test env.project.name == "Linked"                     # reads through the link
            @test dirname(env.manifest_file) == realpath(envdir)   # manifest beside the link
        end
    end
end

# Pkg.jl#4720: reverse-dependency edges built in one pass
@testset "manifest_dependents_map" begin
    u = i -> UUID(UInt128(i))
    mkentry(name, uuid, deps) = EnvFiles.ManifestEntry(
        name, uuid, RegistryTracked(v"1.0.0", nothing, String[]), false,
        deps, Dict{String, UUID}(),
        Dict{String, Union{String, Vector{String}}}(), Dict{String, AppInfo}(),
        nothing, nothing, Dict{String, Any}(),
    )
    # A -> {B, C}, B -> {C}, C -> {}, D isolated
    m = with_manifest(
        EnvFiles.Manifest();
        deps = Dict(
            u(1) => mkentry("A", u(1), Dict("B" => u(2), "C" => u(3))),
            u(2) => mkentry("B", u(2), Dict("C" => u(3))),
            u(3) => mkentry("C", u(3), Dict{String, UUID}()),
            u(4) => mkentry("D", u(4), Dict{String, UUID}()),
        ),
    )
    dependents = manifest_dependents_map(m)
    @test sort(dependents[u(2)]) == [u(1)]
    @test sort(dependents[u(3)]) == [u(1), u(2)]
    @test !haskey(dependents, u(1))     # nothing depends on A
    @test !haskey(dependents, u(4))
    @test isempty(manifest_dependents_map(EnvFiles.Manifest()))
end
