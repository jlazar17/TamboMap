# TamboMap

This is some basic code to help us make the institutional maps for TAMBO.

## Usage

```julia
julia> using Pkg

julia> Pkg.activate(".")

julia> institutions = TamboMap.institutions_from_json("../institutions/");

julia> map = make_map(institutions)

julia> save("TAMBO_map.png", map)
```

![](https://github.com/jlazar17/TamboMap/blob/main/examples/TAMBO_map.png)

You can change the colors of the ocean, and countries like

```julia
julia> make_map(
          institutions, 
          ocean_color=colorant"#002B82",
          country_color_yes=colorant"#B75982",
          country_color_no=colorant"#8BA5C1"
       )
```

![](https://github.com/jlazar17/TamboMap/blob/main/examples/TAMBO_map_miami_nights.png)
