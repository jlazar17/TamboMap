#!/usr/bin/env julia
# Usage: julia --project=. scripts/build_logo_map.jl [--ask-new|--ask-all] <tex_file> [output.png]
# Default: ask-none (render immediately with cached logos)

ask_new = "--ask-new" in ARGS
ask_all = "--ask-all" in ARGS
ask_new && ask_all && error("--ask-new and --ask-all are mutually exclusive")
args = filter(a -> a ∉ ("--ask-new", "--ask-all"), collect(ARGS))

length(args) >= 1 || error("Usage: julia --project=. scripts/build_logo_map.jl [--ask-new|--ask-all] <tex_file> [output.png]")

tex_file   = args[1]
isfile(tex_file) || error("File not found: $tex_file")

default_out = splitext(basename(tex_file))[1] * "_map.png"
out_file    = length(args) >= 2 ? args[2] : default_out

using TamboMap
using CairoMakie: save, @colorant_str

const GEOCODE_CACHE = "geocode_cache"
const LOGO_CACHE    = "logo_cache"

# ── Step 1: Parse affiliations ────────────────────────────────────────────────
println("Parsing affiliations from $tex_file ...")
affs = TamboMap.parse_revtex_affiliations(tex_file)
println("Found $(length(affs)) unique affiliations.")

# ── Step 2: Geocode (network only for new entries) ────────────────────────────
println("Geocoding affiliations (cached entries are instant) ...")
institutions = [TamboMap.geocode_affiliation(a; cache_dir=GEOCODE_CACHE) for a in affs]

# ── Step 3: Determine logo status ────────────────────────────────────────────
function has_logo(inst::TamboMap.Institution)::Bool
    inst.logo_url  !== nothing && return true
    inst.logo_path !== nothing && return true
    sanitized = replace(lowercase(inst.name), r"[^a-z0-9]" => "_")
    return isfile(joinpath(LOGO_CACHE, "$(sanitized).png"))
end

function current_logo_str(inst::TamboMap.Institution)::String
    inst.logo_url  !== nothing && return inst.logo_url
    inst.logo_path !== nothing && return inst.logo_path
    return ""
end

function prompt_logo!(inst, aff)
    short   = length(inst.name) > 70 ? first(inst.name, 70) * "..." : inst.name
    current = current_logo_str(inst)
    if isempty(current)
        print("Logo for \"$short\" (Enter to skip): ")
    else
        print("Logo for \"$short\"\n  current: $current\n  new (Enter to keep): ")
    end
    url = String(strip(readline()))
    isempty(url) && return  # keep existing
    if startswith(url, "http://") || startswith(url, "https://")
        TamboMap.set_logo_url!(aff, url; cache_dir=GEOCODE_CACHE)
        # delete cached PNG so it gets re-downloaded
        sanitized = replace(lowercase(inst.name), r"[^a-z0-9]" => "_")
        cached = joinpath(LOGO_CACHE, "$(sanitized).png")
        isfile(cached) && rm(cached)
    else
        abs_path = isabspath(url) ? url : abspath(url)
        isfile(abs_path) || @warn "File not found: $abs_path"
        TamboMap.set_logo_path!(aff, abs_path; cache_dir=GEOCODE_CACHE)
        sanitized = replace(lowercase(inst.name), r"[^a-z0-9]" => "_")
        cached = joinpath(LOGO_CACHE, "$(sanitized).png")
        isfile(cached) && rm(cached)
    end
end

n_have    = count(has_logo, institutions)
n_total   = length(institutions)
n_missing = n_total - n_have

println("Found $n_total institutions, $n_have already have logos.")

if ask_all
    println("Ask-all mode: showing all institutions. Press Enter to keep existing value.\n")
    for (inst, aff) in zip(institutions, affs)
        prompt_logo!(inst, aff)
    end
    institutions = [TamboMap.geocode_affiliation(a; cache_dir=GEOCODE_CACHE) for a in affs]
elseif ask_new && n_missing > 0
    println("Please provide logo URLs for the remaining $n_missing institutions.")
    println("(Press Enter to skip an institution.)\n")
    for (inst, aff) in zip(institutions, affs)
        has_logo(inst) && continue
        prompt_logo!(inst, aff)
    end
    institutions = [TamboMap.geocode_affiliation(a; cache_dir=GEOCODE_CACHE) for a in affs]
end

n_final = count(has_logo, institutions)
println("\n$n_final/$n_total institutions have logos.")

# ── Step 4: Render map ────────────────────────────────────────────────────────
println("Generating map ...")
fig = make_map_with_logos(
    institutions;
    cache_dir=LOGO_CACHE,
    logo_scale=30.0,
    logo_gap=15.0,
    box_strokewidth=2.0,
    ocean_color=colorant"#002B82",
    country_color_yes=colorant"#B75982",
    country_color_no=colorant"#8BA5C1",
    scatter_color=:white,
    line_color=:black
)
save(out_file, fig; px_per_unit=6)
println("Saved to $out_file")
