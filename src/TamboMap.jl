module TamboMap

using JSON
using Glob
using CairoMakie
using GeoMakie
using GeoMakie.GeoJSON
using FileIO
using ImageIO
using Downloads
using LinearAlgebra

export make_map, make_map_with_logos, remove_background, institutions_from_revtex, set_logo_url!, set_logo_path!

include("./institutions.jl")
include("./logos.jl")
include("./logo_layout.jl")
include("./revtex.jl")

countries_file = GeoMakie.assetpath("vector", "countries.geo.json")
const countries = GeoJSON.read(read(countries_file, String))

function make_map(
    institutions::Vector{TamboMap.Institution};
    ocean_color = :black,
    country_color_yes = :yellow,
    country_color_no = :grey,
    scatter_color = nothing
)
    if typeof(scatter_color)==Nothing
        scatter_color = country_color_no
    end
    lons = -180:180
    lats = -90:90

    inst_countries = getfield.(getfield.(institutions, :location), :country)

    color = [
        country.name in inst_countries ? country_color_yes : country_color_no
        for country in countries
    ]

    set_theme!(backgroundcolor = :transparent)

    map = Figure(figure_padding=20)
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
        strokecolor = :black, strokewidth = 0.25,
        shading=NoShading,
    )

    sc = scatter!(
        ax,
        [i.location.latitude for i in institutions],
        [i.location.longitude for i in institutions],
        color=scatter_color,
        markersize=4,
    )

    translate!(hm, 0, 0, 100) # move above surface plot
    translate!(sc, 0, 0, 101) # move above surface plot
    return map
end

# Globe bounds in normalized eqearth units (proj output ÷ 100_000).
# EqualEarth: lon=±180 → x≈±172.5, lat=±90 → y≈±84.0
const EQEARTH_X_HALF = 172.5
const EQEARTH_Y_HALF = 84.0

# GeoAxis autolimit adds 5 % on each side (10 % total) even when surface! is added.
# These are the actual finallimits the GeoAxis settles on after autoscaling.
const GEO_FINAL_X = EQEARTH_X_HALF * 1.1   # ≈ 189.75
const GEO_FINAL_Y = EQEARTH_Y_HALF * 1.1   # ≈ 92.4

# Overlay axis (ax2) limits.  Aspect ratio matches GEO_FINAL_X/GEO_FINAL_Y so that
# DataAspect makes ax2 the same width as the figure cell.
const OVERLAY_X_HALF = 300.0
const OVERLAY_Y_HALF = OVERLAY_X_HALF * GEO_FINAL_Y / GEO_FINAL_X  # ≈ 146.1

# Approximate scale: eqearth units → ax2 data units (used for logo layout only).
# Line endpoints use a viewport-based lift for pixel-perfect alignment.
const OVERLAY_SCALE = OVERLAY_X_HALF / GEO_FINAL_X  # ≈ 1.581

function make_map_with_logos(
    institutions::Vector{TamboMap.Institution};
    ocean_color = :black,
    country_color_yes = :yellow,
    country_color_no = :grey,
    scatter_color = nothing,
    logo_scale::Float64 = 15.0,
    logo_gap::Float64 = 5.0,
    box_gap::Float64 = 15.0,
    spring_k::Float64 = 0.5,
    repulse_k::Float64 = 500.0,
    boundary_k::Float64 = 100.0,
    n_iter::Int = 500,
    line_color = :white,
    line_width::Float64 = 0.8,
    logo_background = :white,
    logo_padding::Float64 = 3.0,
    logo_corner_radius::Float64 = 4.0,
    box_strokecolor = :black,
    box_strokewidth::Float64 = 0.0,
    cache_dir::String = "logo_cache",
)
    if typeof(scatter_color) == Nothing
        scatter_color = country_color_no
    end
    lons = -180:180
    lats = -90:90

    inst_countries = getfield.(getfield.(institutions, :location), :country)

    color = [
        country.name in inst_countries ? country_color_yes : country_color_no
        for country in countries
    ]

    # ── Pre-compute canvas expansion ───────────────────────────────────────────
    # The EqualEarth map fills the canvas to ±OVERLAY_X_HALF at the equator,
    # leaving no room for logos on the east/west sides.  We expand the canvas
    # in both x and y, but must maintain the GeoAxis aspect ratio so that ax2
    # (DataAspect) perfectly overlays GeoAxis.
    #
    # _fig_x_abs / _fig_y_abs must equal OVERLAY_X_HALF / OVERLAY_Y_HALF.
    # We compute the minimum expansion needed in each direction independently,
    # then pick whichever dominates and derive the other from the fixed ratio.
    _fig_padding = 20
    _fig_width   = 1200
    _cell_width  = _fig_width - 2 * _fig_padding        # 1160

    _canvas_margin = 8.0
    _base_map_y_max = EQEARTH_Y_HALF * OVERLAY_SCALE    # ≈ 132.8
    _est_hh = logo_scale / 2                             # logo half-height
    _est_hw = logo_scale                                 # logo half-width (assumes up to ~2:1 aspect)

    # Expand x first (needed to compute the scale-dependent pole y below).
    _extra_canvas_x = max(0.0, 2.0 * _est_hw + logo_gap + _canvas_margin)
    _fig_x_abs = OVERLAY_X_HALF + _extra_canvas_x

    # When _fig_x_abs > OVERLAY_X_HALF the ax2 coordinate system scales up, so
    # the actual pole y in ax2 data coords grows proportionally — it is NOT fixed
    # at _base_map_y_max.  Estimate it from the EqualEarth/GeoAxis geometry:
    #   pole_y_ax2 ≈ EQEARTH_Y_HALF / GEO_FINAL_X * _fig_x_abs
    _estimated_pole_y = EQEARTH_Y_HALF / GEO_FINAL_X * _fig_x_abs
    _extra_canvas_y = max(0.0,
        _estimated_pole_y + 2 * _est_hh + logo_gap + _canvas_margin + 5.0 - OVERLAY_Y_HALF)
    _fig_y_abs = OVERLAY_Y_HALF + _extra_canvas_y

    # Figure height: ensures ax2 (DataAspect, xlims ±_fig_x_abs, ylims ±_fig_y_abs)
    # is width-limited and fills the cell horizontally, while extending beyond the
    # GeoAxis vertically to accommodate top/bottom logos.
    _min_cell_h = _cell_width * _fig_y_abs / _fig_x_abs
    _fig_height = max(600, ceil(Int, _min_cell_h) + 2 * _fig_padding)

    set_theme!(backgroundcolor = :transparent)

    fig = Figure(size=(_fig_width, _fig_height), figure_padding=_fig_padding)

    # ── Geographic map (GeoAxis, EqualEarth projection) ────────────────────────
    ax = GeoAxis(
        fig[1, 1],
        xticklabelsvisible = false,
        yticklabelsvisible = false,
        xgridvisible = false,
        ygridvisible = false,
    )
    field = [1 for _ in lons, _ in lats]

    surface!(ax, lons, lats, field; colormap=[ocean_color, ocean_color])

    hm = poly!(ax, countries; color=color,
        strokecolor = :black, strokewidth = 0.25,
        shading = NoShading,
    )

    sc = scatter!(
        ax,
        [i.location.latitude for i in institutions],
        [i.location.longitude for i in institutions],
        color = scatter_color,
        strokecolor = :black,
        strokewidth = 0.5,
        markersize = 6,
    )

    translate!(hm, 0, 0, 100)
    translate!(sc, 0, 0, 101)

    # ── Logo overlay axis (regular Axis, same grid cell) ───────────────────────
    # Coordinates are scaled eqearth units: raw eqearth × OVERLAY_SCALE.
    # DataAspect ensures ax2 occupies the same pixel sub-area as GeoAxis so
    # that dot positions projected on GeoAxis align with lines drawn on ax2.
    ax2 = Axis(fig[1, 1]; backgroundcolor=:transparent, aspect=DataAspect())
    hidedecorations!(ax2)
    hidespines!(ax2)
    xlims!(ax2, -_fig_x_abs, _fig_x_abs)
    ylims!(ax2, -_fig_y_abs, _fig_y_abs)

    # ── Load logos, project dot positions, build anchors ──────────────────────
    geo_trans = ax.transform_func[]   # EqualEarth Proj.Transformation

    # Force Makie layout resolution by rendering to a temp file before logo
    # placement.  This makes ax.scene.viewport[] and ax2.scene.viewport[] valid
    # so that dot positions computed below match the positions the lift-based
    # lines will use at final render time.  Without this step, the GeoAxis
    # internal padding (~16 px per side) shifts dot positions by ~3 % versus
    # ax2, causing near-parallel lines to visually cross even though the layout
    # algorithm (which uses approximate positions) reports no crossings.
    _tmp_png = tempname() * ".png"
    save(_tmp_png, fig; px_per_unit=1)
    rm(_tmp_png)
    _ax_vp  = ax.scene.viewport[]
    _ax2_vp = ax2.scene.viewport[]
    _ax_fl  = ax.finallimits[]
    _ax2_fl = ax2.finallimits[]

    # Helper: convert EqualEarth coordinates → exact ax2 data coordinates,
    # using the actual scene viewports resolved above.
    function _eqearth_to_ax2(ex::Float64, ey::Float64)
        px = _ax_vp.origin[1]  + (ex - _ax_fl.origin[1])  / _ax_fl.widths[1]  * _ax_vp.widths[1]
        py = _ax_vp.origin[2]  + (ey - _ax_fl.origin[2])  / _ax_fl.widths[2]  * _ax_vp.widths[2]
        dx = _ax2_fl.origin[1] + (px - _ax2_vp.origin[1]) / _ax2_vp.widths[1] * _ax2_fl.widths[1]
        dy = _ax2_fl.origin[2] + (py - _ax2_vp.origin[2]) / _ax2_vp.widths[2] * _ax2_fl.widths[2]
        (dx, dy)
    end

    # Compute the actual curved map boundary in ax2 space.  Use _eqearth_to_ax2
    # so the boundary is in the same coordinate system as the dot positions.
    _bdy_lats = range(0.0, 90.0, length=91)
    _bdy_y = Float64[]
    _bdy_x = Float64[]
    for lat in _bdy_lats
        pt = Makie.apply_transform(geo_trans, Makie.Point2f(180.0f0, Float32(lat)))
        bx, by = _eqearth_to_ax2(Float64(pt[1]), Float64(pt[2]))
        push!(_bdy_y, abs(by))
        push!(_bdy_x, abs(bx))
    end
    map_boundary = MapBoundary(_bdy_y, _bdy_x, maximum(_bdy_y), maximum(_bdy_x))

    logo_images = []
    anchors = LogoAnchor[]

    for (idx, inst) in enumerate(institutions)
        img = get_logo(inst; cache_dir=cache_dir)
        img === nothing && continue

        # Project dot position to normalized eqearth space, then to exact ax2.
        # Existing scatter uses (location.latitude, location.longitude) as (x, y)
        # which maps to (actual_lon, actual_lat) — see coordinate convention note.
        dot_norm = Makie.apply_transform(geo_trans, Makie.Point2f(
            Float32(inst.location.latitude),   # = actual longitude
            Float32(inst.location.longitude),  # = actual latitude
        ))
        ex = Float64(dot_norm[1])
        ey = Float64(dot_norm[2])
        dot_x, dot_y = _eqearth_to_ax2(ex, ey)

        img_h, img_w = size(img, 2), size(img, 1)  # rotr90 swaps dims: dim1=orig_W, dim2=orig_H
        logo_h = logo_scale + 2 * logo_padding
        logo_w = logo_scale * img_w / img_h + 2 * logo_padding
        push!(logo_images, img)
        push!(anchors, LogoAnchor(idx, (dot_x, dot_y), (logo_w, logo_h)))
    end

    if !isempty(anchors)
        positions = layout_logos(
            anchors, map_boundary;
            spring_k   = spring_k,
            repulse_k  = repulse_k,
            boundary_k = boundary_k,
            n_iter     = n_iter,
            logo_gap   = logo_gap,
            box_gap    = box_gap,
            fig_x_min  = -_fig_x_abs,
            fig_x_max  =  _fig_x_abs,
            fig_y_min  = -_fig_y_abs,
            fig_y_max  =  _fig_y_abs,
        )

        function _rounded_rect_points(cx, cy, hw, hh, r; n=10)
            r = min(r, hw, hh)
            pts = Point2f[]
            for (ox, oy, a0) in (
                (cx + hw - r, cy + hh - r, 0.0),     # top-right
                (cx - hw + r, cy + hh - r, π/2),     # top-left
                (cx - hw + r, cy - hh + r, π),       # bottom-left
                (cx + hw - r, cy - hh + r, 3π/2),    # bottom-right
            )
                for i in 0:n
                    a = a0 + i * (π/2) / n
                    push!(pts, Point2f(ox + r*cos(a), oy + r*sin(a)))
                end
            end
            return pts
        end

        for (k, (anchor, pos)) in enumerate(zip(anchors, positions))
            img = logo_images[k]
            cx, cy = pos
            hw = anchor.logo_size[1] / 2   # includes padding
            hh = anchor.logo_size[2] / 2   # includes padding
            iw = hw - logo_padding          # image-only half-width
            ih = hh - logo_padding          # image-only half-height

            # dot_x, dot_y are exact ax2 positions computed from the pre-resolved
            # scene viewports (see _eqearth_to_ax2 above), so the line endpoints
            # land precisely on the scatter markers without needing a lift.
            bg_plot = poly!(ax2,
                _rounded_rect_points(cx, cy, hw, hh, logo_corner_radius);
                color = logo_background,
                strokecolor = box_strokecolor,
                strokewidth = box_strokewidth,
            )
            img_plot = image!(ax2,
                (cx - iw, cx + iw),
                (cy - ih, cy + ih),
                img,
            )
            line_plot = lines!(ax2,
                [anchor.dot_pos[1], cx],
                [anchor.dot_pos[2], cy];
                color     = line_color,
                linewidth = line_width,
            )
            translate!(line_plot, 0, 0, 102)
            translate!(bg_plot,   0, 0, 103)
            translate!(img_plot,  0, 0, 104)
        end
    end

    return fig
end

end # module TamboMap
