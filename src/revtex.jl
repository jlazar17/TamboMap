
# ── LaTeX decoding ─────────────────────────────────────────────────────────────

# Flat replacement table ordered longest-match first to avoid partial matches.
const LATEX_REPLACEMENTS = [
    # umlaut
    "\\\"{a}" => "ä", "\\\"{o}" => "ö", "\\\"{u}" => "ü",
    "\\\"{A}" => "Ä", "\\\"{O}" => "Ö", "\\\"{U}" => "Ü",
    "\\\"a"   => "ä", "\\\"o"   => "ö", "\\\"u"   => "ü",
    "\\\"A"   => "Ä", "\\\"O"   => "Ö", "\\\"U"   => "Ü",
    # acute
    "\\'{a}" => "á", "\\'{e}" => "é", "\\'{i}" => "í",
    "\\'{o}" => "ó", "\\'{u}" => "ú", "\\'{A}" => "Á",
    "\\'{E}" => "É", "\\'{I}" => "Í", "\\'{O}" => "Ó", "\\'{U}" => "Ú",
    "\\'a"   => "á", "\\'e"   => "é", "\\'i"   => "í",
    "\\'o"   => "ó", "\\'u"   => "ú",
    # grave
    "\\`{a}" => "à", "\\`{e}" => "è", "\\`{i}" => "ì",
    "\\`{o}" => "ò", "\\`{u}" => "ù",
    "\\`a"   => "à", "\\`e"   => "è", "\\`i"   => "ì",
    "\\`o"   => "ò", "\\`u"   => "ù",
    # circumflex
    "\\^{a}" => "â", "\\^{e}" => "ê", "\\^{i}" => "î",
    "\\^{o}" => "ô", "\\^{u}" => "û",
    "\\^a"   => "â", "\\^e"   => "ê", "\\^i"   => "î",
    "\\^o"   => "ô", "\\^u"   => "û",
    # tilde letter
    "\\~{n}" => "ñ", "\\~{N}" => "Ñ", "\\~{a}" => "ã", "\\~{o}" => "õ",
    "\\~n"   => "ñ", "\\~N"   => "Ñ",
    # cedilla
    "\\c{c}" => "ç", "\\c{C}" => "Ç",
    # dotless i/j with accents (must come before bare \i/\j)
    "\\'{\\i}" => "í", "\\`{\\i}" => "ì", "\\\"{\\i}" => "ï",
    "\\^{\\i}" => "î", "\\~{\\i}" => "ĩ",
    "\\'\\i"   => "í", "\\`\\i"   => "ì", "\\\"\\i"   => "ï",
    # dotless i/j bare
    "{\\i}" => "i", "{\\j}" => "j",
    "\\i"   => "i", "\\j"   => "j",
    # ring
    "\\r{a}" => "å", "\\r{A}" => "Å",
    # stroke
    "{\\o}"  => "ø", "{\\O}"  => "Ø",
    "\\o"    => "ø", "\\O"    => "Ø",
    # ligatures
    "{\\ae}" => "æ", "{\\AE}" => "Æ",
    "{\\ss}" => "ß",
    # special characters
    "\\&"    => "&",
    "\\%"    => "%",
    # tilde spacing → regular space
    "~"      => " ",
]

function decode_latex(s::String)::String
    for (pat, rep) in LATEX_REPLACEMENTS
        s = replace(s, pat => rep)
    end
    # Strip remaining braces
    s = replace(s, "{" => "", "}" => "")
    return strip(s)
end

# ── Affiliation splitting ───────────────────────────────────────────────────────

"""
    split_multi_affiliation(s) -> Vector{String}

Split compound affiliations such as
"Lulea University of Technology, Sweden, and INFN, Sezione di Padova, Italy"
on `, and ` where the next word starts with an uppercase letter.
Entries like "Arthur B. McDonald ... Institute" are not split.
"""
function split_multi_affiliation(s::String)::Vector{String}
    parts = split(s, r",\s+and\s+(?=[A-Z])")
    return strip.(parts)
end

# ── RevTeX parser ───────────────────────────────────────────────────────────────

"""
    parse_revtex_affiliations(tex_file) -> Vector{String}

Extract unique, decoded, split affiliation strings from a RevTeX author file.
"""
function parse_revtex_affiliations(tex_file::String)::Vector{String}
    text = read(tex_file, String)

    # Extract all \affiliation{...} blocks (handles multi-line content)
    raw_affs = String[]
    # Allow single-level nested braces (e.g. \'{\i}, \'{u}) inside the content.
    for m in eachmatch(r"\\affiliation\{((?:[^{}]|\{[^}]*\})*)\}", text)
        push!(raw_affs, m.captures[1])
    end

    # Decode and split
    decoded = String[]
    for raw in raw_affs
        decoded_str = decode_latex(raw)
        for part in split_multi_affiliation(decoded_str)
            push!(decoded, String(part))
        end
    end

    # Deduplicate (preserve first-seen order)
    seen = Set{String}()
    unique_affs = String[]
    for a in decoded
        if a ∉ seen
            push!(seen, a)
            push!(unique_affs, a)
        end
    end
    return unique_affs
end

# ── Geocoding with Nominatim (OpenStreetMap) ────────────────────────────────────

# Map Nominatim English country names to the names used in the GeoMakie GeoJSON.
const COUNTRY_NAME_MAP = Dict(
    "United States" => "United States of America",
)

# Demonyms that appear in affiliation strings but signal a country.
const DEMONYM_MAP = Dict(
    "Canadian"  => "Canada",
    "American"  => "United States of America",
    "Chilean"   => "Chile",
    "Peruvian"  => "Peru",
    "Swedish"   => "Sweden",
    "Italian"   => "Italy",
    "Spanish"   => "Spain",
    "Danish"    => "Denmark",
    "Belgian"   => "Belgium",
    "British"   => "United Kingdom",
    "Japanese"  => "Japan",
    "Chinese"   => "China",
    "Australian"=> "Australia",
)

# If any demonym from DEMONYM_MAP appears as a word in aff_str, return the
# corresponding country string; otherwise return nothing.
function _demonym_country(aff_str::String)::Union{String,Nothing}
    for (demonym, country) in DEMONYM_MAP
        if occursin(Regex("\\b" * demonym * "\\b"), aff_str)
            return country
        end
    end
    return nothing
end

# Extract a "city, country" query string from a full affiliation string.
# Walks forward through the last 3 comma-separated components (skipping
# postal codes and state abbreviations) to find the most specific city.
function _extract_city_country(aff_str::String)::String
    parts = strip.(split(aff_str, r",\s*"))
    length(parts) < 2 && return aff_str
    country = String(parts[end])
    skip_prefixes = ("Jr.", "Calle", "Apartado", "Jirón", "Av.", "Madingley Road",
                     "Sezione", "Principado", "Provincia")
    # Walk forward through the last 3 components so we find the earliest
    # (most specific) city before broader state/province names.
    for i in max(1, length(parts)-3):length(parts)-1
        p = String(parts[i])
        # Strip leading postal codes: "DK-2100 ", "15782 "
        p = replace(p, r"^[A-Za-z]{0,3}-?\d[\w-]*\s+" => "")
        # Strip trailing postal codes: " MA 02138", " 15088", " CB3 0HA"
        p = replace(p, r"\s+[A-Z]{0,2}\s*\d[\w\s-]*$" => "")
        p = strip(p)
        isempty(p) && continue
        isdigit(first(p)) && continue              # starts with digit → zip/street number
        occursin(r"^[A-Z]{2}$", p) && continue    # two-letter state abbreviation
        any(startswith(p, s) for s in skip_prefixes) && continue
        return "$p, $country"
    end
    return aff_str  # fallback: use the full string
end

# Percent-encode a string for use in a URL query parameter.
function _urlencode(s::String)::String
    out = IOBuffer()
    for c in s
        if c in ('A':'Z'..., 'a':'z'..., '0':'9'..., '-', '_', '.', '~')
            write(out, c)
        else
            for byte in codeunits(string(c))
                write(out, '%')
                write(out, uppercase(string(byte, base=16, pad=2)))
            end
        end
    end
    return String(take!(out))
end

"""
    geocode_affiliation(aff_str; cache_dir) -> Institution

Geocode `aff_str` via the Nominatim (OpenStreetMap) API.
No API key required. Results are cached as JSON files under `cache_dir`
keyed by a hash of the affiliation string. A 1-second sleep is inserted
between live API calls to respect Nominatim's usage policy.
"""
function geocode_affiliation(aff_str::String; cache_dir::String="geocode_cache")::Institution
    mkpath(cache_dir)
    cache_key = string(hash(aff_str), base=16)
    cache_file = joinpath(cache_dir, cache_key * ".json")

    if isfile(cache_file)
        d = JSON.parsefile(cache_file)
        loc = Location(
            d["country"],
            d["city"],
            d["lat"],   # actual latitude → Location.longitude (swapped convention)
            d["lng"],   # actual longitude → Location.latitude (swapped convention)
        )
        logo_url  = get(d, "logo_url",  nothing)
        logo_path = get(d, "logo_path", nothing)
        return Institution(aff_str, loc, logo_path, logo_url)
    end

    function _nominatim_query(q::String)
        encoded_q = _urlencode(q)
        url_q = "https://nominatim.openstreetmap.org/search?q=$(encoded_q)&format=json&addressdetails=1&limit=1"
        io = IOBuffer()
        Downloads.download(url_q, io; headers=["User-Agent" => "TamboMap/0.1 (julia scientific map tool)", "Accept-Language" => "en"])
        return JSON.parse(String(take!(io)))
    end

    # Build candidate query list:
    #   1. City-level query extracted from the affiliation string (preferred)
    #   2. First component + demonym-inferred country (e.g. "Queen's University, Canada")
    #   3. Progressive front-stripping of the full string (fallback)
    #   4. Each individual component
    city_query = _extract_city_country(aff_str)
    parts = split(aff_str, r",\s*")
    candidates = String[city_query]
    if (dem_country = _demonym_country(aff_str)) !== nothing
        q = "$(parts[1]), $dem_country"
        q ∉ candidates && push!(candidates, q)
    end
    for i in 1:length(parts)
        q = join(parts[i:end], ", ")
        q ∉ candidates && push!(candidates, q)
    end
    for p in parts
        String(p) ∉ candidates && push!(candidates, String(p))
    end

    results = []
    for (k, candidate) in enumerate(candidates)
        results = _nominatim_query(candidate)
        isempty(results) || break
        k < length(candidates) && sleep(1)  # rate limit between retries
    end

    isempty(results) && error("Nominatim returned no results for: $aff_str")

    result = results[1]
    lat = parse(Float64, result["lat"])
    lng = parse(Float64, result["lon"])

    addr = get(result, "address", Dict())
    raw_country = get(addr, "country", "")
    country = get(COUNTRY_NAME_MAP, raw_country, raw_country)
    city = ""
    for key in ("city", "town", "village", "municipality", "county", "state")
        if haskey(addr, key)
            city = addr[key]
            break
        end
    end

    cache_data = Dict("country" => country, "city" => city, "lat" => lat, "lng" => lng)
    open(cache_file, "w") do f
        write(f, JSON.json(cache_data))
    end

    sleep(1)  # Nominatim rate limit

    # Use same swapped convention as institution_from_json:
    #   3rd arg (Location.longitude) = actual latitude
    #   4th arg (Location.latitude)  = actual longitude
    loc = Location(country, city, lat, lng)
    return Institution(aff_str, loc)
end

"""
    set_logo_url!(aff_str, url; cache_dir="geocode_cache")

Persist a logo URL in the geocode_cache JSON for `aff_str` so that
subsequent calls to `geocode_affiliation` return an Institution with
`logo_url` set. The affiliation must already be geocoded.
"""
function set_logo_url!(aff_str::String, url::String;
                       cache_dir::String = "geocode_cache")
    cache_key  = string(hash(aff_str), base=16)
    cache_file = joinpath(cache_dir, cache_key * ".json")
    isfile(cache_file) || error("No geocode cache entry for: $aff_str")
    d = JSON.parsefile(cache_file)
    d["logo_url"] = url
    open(cache_file, "w") do f; write(f, JSON.json(d)); end
end

"""
    set_logo_path!(aff_str, path; cache_dir="geocode_cache")

Persist a local logo file path in the geocode_cache JSON for `aff_str`.
The affiliation must already be geocoded.
"""
function set_logo_path!(aff_str::String, path::String;
                        cache_dir::String = "geocode_cache")
    cache_key  = string(hash(aff_str), base=16)
    cache_file = joinpath(cache_dir, cache_key * ".json")
    isfile(cache_file) || error("No geocode cache entry for: $aff_str")
    d = JSON.parsefile(cache_file)
    d["logo_path"] = path
    open(cache_file, "w") do f; write(f, JSON.json(d)); end
end

# ── Public API ──────────────────────────────────────────────────────────────────

"""
    institutions_from_revtex(tex_file; cache_dir="geocode_cache") -> Vector{Institution}

Parse a RevTeX author file, geocode each unique affiliation via Nominatim
(OpenStreetMap), and return a `Vector{Institution}` ready for `make_map` or
`make_map_with_logos`.

No API key required. Results are cached under `cache_dir` so repeated calls
do not hit the network.
"""
function institutions_from_revtex(
    tex_file::String;
    cache_dir::String = "geocode_cache",
)::Vector{Institution}
    affs = parse_revtex_affiliations(tex_file)
    return [geocode_affiliation(a; cache_dir=cache_dir) for a in affs]
end
