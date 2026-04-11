using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using TamboMap
using GeoMakie: save
using Colors
using FileIO
using ImageIO

# ---- Create placeholder logo images (three distinct colours) ----
function make_placeholder(bg_hex, w=64, h=64)
    bg     = parse(Colorant, bg_hex)
    border = colorant"#FFFFFF"
    img    = fill(bg, h, w)
    for i in 1:h, j in 1:w
        if i <= 4 || i >= h - 3 || j <= 4 || j >= w - 3
            img[i, j] = border
        end
    end
    img
end

mkpath(joinpath(@__DIR__, "..", "logo_cache"))

colors  = ["#3A86FF", "#FF6B6B", "#06D6A0"]
paths   = [joinpath(@__DIR__, "..", "logo_cache", "placeholder_$(i).png") for i in 1:3]
for (path, hex) in zip(paths, colors)
    FileIO.save(path, make_placeholder(hex))
end
println("Placeholders saved.")

# ---- Synthetic institutions spread around the world ----
# Location(country, city, arg3, arg4) stores arg3 as loc.longitude and arg4
# as loc.latitude — but the rendering code uses (loc.latitude, loc.longitude)
# as (actual_lon, actual_lat).  So: arg3 = actual_lat, arg4 = actual_lon.
synthetic = [
    # North America
    ("New York",     TamboMap.Location("United States of America", "New York",      40.7128,  -74.006),   paths[1]),
    ("Los Angeles",  TamboMap.Location("United States of America", "Los Angeles",   34.0522, -118.2437),  paths[1]),
    ("Chicago",      TamboMap.Location("United States of America", "Chicago",       41.8781,  -87.6298),  paths[1]),
    ("Toronto",      TamboMap.Location("Canada",        "Toronto",       43.6532,  -79.3832),  paths[1]),
    ("Mexico City",  TamboMap.Location("Mexico",        "Mexico City",   19.4326,  -99.1332),  paths[2]),
    # South America
    ("Sao Paulo",    TamboMap.Location("Brazil",        "Sao Paulo",    -23.5505,  -46.6333),  paths[2]),
    ("Buenos Aires", TamboMap.Location("Argentina",     "Buenos Aires", -34.6037,  -58.3816),  paths[2]),
    # Europe
    ("London",       TamboMap.Location("United Kingdom","London",        51.5074,   -0.1276),  paths[3]),
    ("Paris",        TamboMap.Location("France",        "Paris",         48.8566,    2.3522),  paths[3]),
    ("Berlin",       TamboMap.Location("Germany",       "Berlin",        52.5200,   13.4050),  paths[3]),
    ("Moscow",       TamboMap.Location("Russia",        "Moscow",        55.7558,   37.6173),  paths[3]),
    # Africa
    ("Nairobi",      TamboMap.Location("Kenya",         "Nairobi",       -1.2921,   36.8219),  paths[2]),
    ("Cairo",        TamboMap.Location("Egypt",         "Cairo",         30.0444,   31.2357),  paths[2]),
    # Asia
    ("Tokyo",        TamboMap.Location("Japan",         "Tokyo",         35.6895,  139.6917),  paths[1]),
    ("Beijing",      TamboMap.Location("China",         "Beijing",       39.9042,  116.4074),  paths[1]),
    ("Mumbai",       TamboMap.Location("India",         "Mumbai",        19.0760,   72.8777),  paths[2]),
    ("Singapore",    TamboMap.Location("Singapore",     "Singapore",      1.3521,  103.8198),  paths[3]),
    # Oceania
    ("Sydney",       TamboMap.Location("Australia",     "Sydney",       -33.8688,  151.2093),  paths[3]),
]

institutions = [
    TamboMap.Institution(name, loc, path, nothing)
    for (name, loc, path) in synthetic
]

println("Using $(length(institutions)) synthetic institutions.")

# ---- Render ----
fig = make_map_with_logos(
    institutions;
    ocean_color       = :black,
    country_color_yes = :yellow,
    country_color_no  = :grey,
    scatter_color     = :white,
    logo_scale        = 40.0,
    spring_k          = 0.5,
    repulse_k         = 600.0,
    boundary_k        = 100.0,
    n_iter            = 600,
    line_color        = :white,
    line_width        = 0.8,
)

out = joinpath(@__DIR__, "logo_map.png")
save(out, fig; px_per_unit=2)
println("Saved: $out")
