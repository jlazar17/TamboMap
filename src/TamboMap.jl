module TamboMap

using JSON
using Glob
using CairoMakie
using GeoMakie

include("./institutions.jl")

# First, make a surface plot
lons = -180:180
lats = -90:90
field = [exp(cosd(l)) + 3(y/90) for l in lons, y in lats]

fig = Figure()
ax = GeoAxis(fig[1,1])
sf = surface!(ax, lons, lats, field; shading = NoShading)
cb1 = Colorbar(fig[1,2], sf; label = "field", height = Relative(0.65))

using GeoMakie.GeoJSON
countries_file = GeoMakie.assetpath("vector", "countries.geo.json")
countries = GeoJSON.read(read(countries_file, String))

n = length(countries)
hm = poly!(ax, countries; color= 1:n, colormap = :dense,
    strokecolor = :black, strokewidth = 0.5,
)
translate!(hm, 0, 0, 100) # move above surface plot

fig

end # module TamboMap
