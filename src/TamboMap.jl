module TamboMap

using JSON
using Glob
using CairoMakie
using GeoMakie
using GeoMakie.GeoJSON

export make_map, remove_background

include("./institutions.jl")

countries_file = GeoMakie.assetpath("vector", "countries.geo.json")
const countries = GeoJSON.read(read(countries_file, String))

function make_map(
    institutions::Vector{TamboMap.Institution};
    ocean_color = :black,
    country_color_yes = :yellow,
    country_color_no = :grey,
)
    lons = -180:180
    lats = -90:90

    inst_countries = getfield.(getfield.(institutions, :location), :country)

    color = [
        country.name in inst_countries ? country_color_yes : country_color_no
        for country in countries
    ]

    set_theme!(backgroundcolor = :transparent)

    map = Figure()
    ax = GeoAxis(
        map[1,1],
        xticklabelsvisible = false,
        yticklabelsvisible = false,
        xgridvisible=false,
        ygridvisible=false,
    )
    field = [1 for _ in lons, _ in lats]

    surface!(ax, lons, lats, field; colormap=[ocean_color, ocean_color])

    hm = poly!(ax, countries; color=color,
        strokecolor = :black, strokewidth = 0.5,
        shading=NoShading,

    )
    translate!(hm, 0, 0, 100) # move above surface plot

    return map
end

end # module TamboMap
