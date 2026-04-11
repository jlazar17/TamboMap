using LinearAlgebra

# Stores the actual (curved) map boundary as a lookup table.
# y_abs_vals: sorted ascending, y_abs_vals[1] ≈ 0 (equator)
# x_max_vals: max x extent at the corresponding |y|  (decreasing toward poles)
struct MapBoundary
    y_abs_vals::Vector{Float64}
    x_max_vals::Vector{Float64}
    y_max::Float64   # max |y| of the map (at the poles)
    x_max::Float64   # max x of the map (at the equator)
end

# Linear-interpolate x_max for a given |y|.
function x_max_at_y(bdy::MapBoundary, y_abs::Float64)::Float64
    y_abs = clamp(y_abs, 0.0, bdy.y_max)
    i = searchsortedlast(bdy.y_abs_vals, y_abs)
    i == 0 && return bdy.x_max_vals[1]
    i >= length(bdy.y_abs_vals) && return bdy.x_max_vals[end]
    t = (y_abs - bdy.y_abs_vals[i]) / (bdy.y_abs_vals[i+1] - bdy.y_abs_vals[i])
    return bdy.x_max_vals[i] * (1 - t) + bdy.x_max_vals[i+1] * t
end

# Binary-search for the distance t along the unit direction (nx, ny) at which
# the logo center just clears the map exclusion zone (boundary + logo + gap).
function boundary_push_distance(
    nx::Float64, ny::Float64,
    bdy::MapBoundary,
    gap::Float64, hw::Float64, hh::Float64,
)::Float64
    t_lo, t_hi = 0.0, 600.0
    for _ in 1:60
        t_mid = (t_lo + t_hi) / 2
        x_exc = x_max_at_y(bdy, max(0.0, abs(t_mid * ny) - hh)) + hw + gap
        y_exc = bdy.y_max + hh + gap
        if abs(t_mid * nx) < x_exc && abs(t_mid * ny) < y_exc
            t_lo = t_mid   # still inside, need to go further
        else
            t_hi = t_mid   # outside, can come back
        end
    end
    return t_hi
end

struct LogoAnchor
    institution_index::Int
    dot_pos::Tuple{Float64,Float64}  # (x, y) matching scatter convention
    logo_size::Tuple{Float64,Float64}  # (w, h) in data coords
end

mutable struct LogoState
    positions::Vector{Tuple{Float64,Float64}}
    anchors::Vector{LogoAnchor}
end

# Initialize each logo by projecting outward from the map center through its
# institution dot to the figure perimeter.  This keeps logos near their dots
# from the start, minimizing connector-line crossings.
# Coordinates are in ax2 data space (scaled eqearth units, OVERLAY_SCALE ≈ 1.212).
# Globe bounds in ax2 space: x ≈ ±273, y ≈ ±133.  Figure bounds: ±300 × ±146.
function initialize_positions(
    anchors::Vector{LogoAnchor};
    x_fig_min::Float64=-300.0,
    x_fig_max::Float64=300.0,
    y_fig_min::Float64=-146.0,
    y_fig_max::Float64=146.0,
)::Vector{Tuple{Float64,Float64}}
    n = length(anchors)
    positions = Vector{Tuple{Float64,Float64}}(undef, n)
    hw = (x_fig_max - x_fig_min) / 2
    hh = (y_fig_max - y_fig_min) / 2

    for i in 1:n
        dx, dy = anchors[i].dot_pos
        dist = sqrt(dx^2 + dy^2)
        if dist < 1e-6
            # Dot at map center: fall back to evenly-spaced angle
            angle = 2π * (i - 1) / n
            dx, dy = cos(angle), sin(angle)
            dist = 1.0
        end
        # Unit vector from center toward the institution dot
        nx, ny = dx / dist, dy / dist
        # Intersect that ray with the figure bounding box
        if abs(nx) * hh >= abs(ny) * hw
            t = hw / abs(nx)
        else
            t = hh / abs(ny)
        end
        # Place slightly inward from the edge
        positions[i] = (0.9 * t * nx, 0.9 * t * ny)
    end
    return positions
end

function segments_intersect(
    p1::Tuple{Float64,Float64},
    p2::Tuple{Float64,Float64},
    p3::Tuple{Float64,Float64},
    p4::Tuple{Float64,Float64},
)::Bool
    function cross2d(o, a, b)
        return (a[1] - o[1]) * (b[2] - o[2]) - (a[2] - o[2]) * (b[1] - o[1])
    end
    d1 = cross2d(p3, p4, p1)
    d2 = cross2d(p3, p4, p2)
    d3 = cross2d(p1, p2, p3)
    d4 = cross2d(p1, p2, p4)
    if ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) &&
       ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0))
        return true
    end
    return false
end

function compute_forces(
    state::LogoState,
    map_boundary::MapBoundary;
    spring_k::Float64=0.5,
    repulse_k::Float64=500.0,
    boundary_k::Float64=20.0,
    logo_gap::Float64=5.0,
    fig_x_min::Float64=-300.0,
    fig_x_max::Float64=300.0,
    fig_y_min::Float64=-146.0,
    fig_y_max::Float64=146.0,
)::Vector{Tuple{Float64,Float64}}
    n = length(state.positions)
    forces = [(0.0, 0.0) for _ in 1:n]
    fig_k = boundary_k * 0.5   # softer walls at figure edges

    for i in 1:n
        pos_i = state.positions[i]
        dot_i = state.anchors[i].dot_pos
        hw_i  = state.anchors[i].logo_size[1] / 2
        hh_i  = state.anchors[i].logo_size[2] / 2
        x, y  = pos_i

        # Spring force: pull logo toward its institution dot.  This minimises the
        # visible line length (dot → nearest logo edge).  boundary_k and
        # enforce_margin_boundary! keep logos outside the map regardless.
        dist_dot = sqrt(dot_i[1]^2 + dot_i[2]^2)
        if dist_dot < 1e-6
            nx_dot, ny_dot = 1.0, 0.0
        else
            nx_dot, ny_dot = dot_i[1] / dist_dot, dot_i[2] / dist_dot
        end
        fx = spring_k * (dot_i[1] - x)
        fy = spring_k * (dot_i[2] - y)
        forces[i] = (forces[i][1] + fx, forces[i][2] + fy)

        # boundary_push_distance still needed for the radial boundary spring below.
        t_bdy = boundary_push_distance(nx_dot, ny_dot, map_boundary, logo_gap, hw_i, hh_i)

        # Pairwise repulsion between logos
        for j in 1:n
            if i == j; continue; end
            pos_j = state.positions[j]
            hw_j  = state.anchors[j].logo_size[1] / 2
            hh_j  = state.anchors[j].logo_size[2] / 2
            dx = x - pos_j[1]
            dy = y - pos_j[2]
            eff_dist = sqrt(dx^2 + dy^2) + hw_i + hw_j + hh_i + hh_j
            if eff_dist < 1e-6; eff_dist = 1e-6; end
            rfx = repulse_k * dx / eff_dist^3
            rfy = repulse_k * dy / eff_dist^3
            forces[i] = (forces[i][1] + rfx, forces[i][2] + rfy)
        end

        # Boundary spring: symmetric 1-D spring along the dot-direction ray.
        # t_bdy is where the logo just clears the map + gap; t_cur is where it
        # actually sits along that ray.  Positive (t_bdy - t_cur) means the logo
        # is inside the boundary → push outward.  Negative means the logo has
        # drifted away from the map → pull it back in.  This keeps every logo
        # pinned to the boundary perimeter from both sides.
        t_cur = nx_dot * x + ny_dot * y
        bnd_f = boundary_k * (t_bdy - t_cur)
        forces[i] = (forces[i][1] + bnd_f * nx_dot,
                     forces[i][2] + bnd_f * ny_dot)

        # Figure-edge repulsion (soft walls keep logos visible).
        left_pen  = (fig_x_min + hw_i) - x
        right_pen = x - (fig_x_max - hw_i)
        bot_pen   = (fig_y_min + hh_i) - y
        top_pen   = y - (fig_y_max - hh_i)
        if left_pen  > 0; forces[i] = (forces[i][1] + fig_k * left_pen,  forces[i][2]); end
        if right_pen > 0; forces[i] = (forces[i][1] - fig_k * right_pen, forces[i][2]); end
        if bot_pen   > 0; forces[i] = (forces[i][1], forces[i][2] + fig_k * bot_pen ); end
        if top_pen   > 0; forces[i] = (forces[i][1], forces[i][2] - fig_k * top_pen ); end
    end

    return forces
end

# Scan all pairs of connector lines (dot→logo).  If two lines cross, swap
# the logo positions so they no longer cross.  Repeat until no swaps are
# needed or max_passes is reached.  This is O(n²) per pass but n is small.
function uncross_positions!(
    positions::Vector{Tuple{Float64,Float64}},
    anchors::Vector{LogoAnchor};
    max_passes::Int = 10,
)
    n = length(positions)
    for _ in 1:max_passes
        any_swap = false
        for i in 1:n
            for j in (i + 1):n
                if segments_intersect(
                    anchors[i].dot_pos, positions[i],
                    anchors[j].dot_pos, positions[j],
                )
                    positions[i], positions[j] = positions[j], positions[i]
                    any_swap = true
                end
            end
        end
        !any_swap && break
    end
end

function enforce_margin_boundary!(
    positions::Vector{Tuple{Float64,Float64}},
    logo_sizes::Vector{Tuple{Float64,Float64}},
    anchors::Vector{LogoAnchor},
    map_boundary::MapBoundary;
    logo_gap::Float64=5.0,
    canvas_margin::Float64=8.0,
    fig_x_min::Float64=-300.0,
    fig_x_max::Float64=300.0,
    fig_y_min::Float64=-146.0,
    fig_y_max::Float64=146.0,
)
    for i in eachindex(positions)
        x, y = positions[i]
        hw = logo_sizes[i][1] / 2
        hh = logo_sizes[i][2] / 2

        # Clamp to figure bounds, keeping logos canvas_margin units clear of
        # the axis clip boundary so they are never partially cropped.
        x = clamp(x, fig_x_min + hw + canvas_margin, fig_x_max - hw - canvas_margin)
        y = clamp(y, fig_y_min + hh + canvas_margin, fig_y_max - hh - canvas_margin)

        # Check against the actual curved map boundary (+ logo size + gap).
        x_exc = x_max_at_y(map_boundary, max(0.0, abs(y) - hh)) + hw + logo_gap
        y_exc = map_boundary.y_max + hh + logo_gap
        in_map = abs(x) < x_exc && abs(y) < y_exc

        # If the logo is pinned at the canvas margin edge, the boundary push
        # cannot move it further out.  Applying the push would reset the OTHER
        # coordinate (e.g. x for a logo at the canvas top), undoing any
        # separation achieved by separate_overlapping!.  Skip the push; the
        # logo will remain at the canvas edge for the duration of cleanup.
        x_edge = fig_x_max - hw - canvas_margin
        y_edge = fig_y_max - hh - canvas_margin
        at_canvas_edge = abs(x) >= x_edge - 0.5 || abs(y) >= y_edge - 0.5

        if in_map && !at_canvas_edge
            dot_x, dot_y = anchors[i].dot_pos
            dist = sqrt(dot_x^2 + dot_y^2)
            if dist < 1e-6
                dist = sqrt(x^2 + y^2)
                if dist < 1e-6
                    dot_x, dot_y, dist = 1.0, 0.0, 1.0
                else
                    dot_x, dot_y = x, y
                end
            end
            nx, ny = dot_x / dist, dot_y / dist
            t = boundary_push_distance(nx, ny, map_boundary, logo_gap, hw, hh)
            x = clamp(t * nx, fig_x_min + hw + canvas_margin, fig_x_max - hw - canvas_margin)
            y = clamp(t * ny, fig_y_min + hh + canvas_margin, fig_y_max - hh - canvas_margin)
        elseif in_map && abs(x) >= x_edge - 0.5
            # Logo is pinned at the canvas x-edge but still overlaps the map oval
            # (common at equatorial longitudes where the EqualEarth projection fills
            # nearly the full canvas width).  Slide poleward along the canvas edge
            # until the logo clears the map.
            dot_y = anchors[i].dot_pos[2]
            sy = if abs(dot_y) >= 5.0
                dot_y >= 0.0 ? 1.0 : -1.0
            else
                y >= 0.0 ? 1.0 : -1.0
            end
            y_abs_hi = fig_y_max - hh - canvas_margin
            y_lo2, y_hi2 = abs(y), y_abs_hi
            for _ in 1:60
                y_mid2 = (y_lo2 + y_hi2) / 2
                x_exc_test = x_max_at_y(map_boundary, max(0.0, y_mid2 - hh)) + hw + logo_gap
                if abs(x) < x_exc_test
                    y_lo2 = y_mid2
                else
                    y_hi2 = y_mid2
                end
            end
            y = clamp(sy * y_hi2, fig_y_min + hh + canvas_margin, fig_y_max - hh - canvas_margin)
        end

        positions[i] = (x, y)
    end
end

# Hard AABB separation using Jacobi-style iteration: all displacements for
# each logo are accumulated from all overlapping pairs, then applied at once.
# This avoids the anti-convergence cycles of Gauss-Seidel when multiple logos
# compete for the same region.
#
# canvas_* limits are used to detect logos pinned at canvas edges:
#   - logos at the y-edge are separated along x (y-push would be clamped back)
#   - logos at the x-edge are separated along y
#   - one-sided push: a canvas-pinned logo does not move; the free logo gets
#     the full displacement so enforce does not undo it.
function separate_overlapping!(
    positions::Vector{Tuple{Float64,Float64}},
    logo_sizes::Vector{Tuple{Float64,Float64}};
    max_iter::Int=200,
    box_gap::Float64=5.0,
    canvas_margin::Float64=8.0,
    fig_x_min::Float64=-300.0,
    fig_x_max::Float64=300.0,
    fig_y_min::Float64=-146.0,
    fig_y_max::Float64=146.0,
)
    n = length(positions)
    dx_acc = zeros(Float64, n)
    dy_acc = zeros(Float64, n)
    wt     = zeros(Float64, n)

    for _ in 1:max_iter
        fill!(dx_acc, 0.0); fill!(dy_acc, 0.0); fill!(wt, 0.0)
        any_overlap = false

        for i in 1:n
            xi, yi = positions[i]
            hwi = logo_sizes[i][1] / 2
            hhi = logo_sizes[i][2] / 2
            y_lim = fig_y_max - canvas_margin
            x_lim = fig_x_max - canvas_margin
            i_at_ytop  = abs(yi) >= y_lim - hhi - 0.5
            i_at_xedge = abs(xi) >= x_lim - hwi - 0.5

            for j in (i + 1):n
                xj, yj = positions[j]
                hwj = logo_sizes[j][1] / 2
                hhj = logo_sizes[j][2] / 2
                j_at_ytop  = abs(yj) >= y_lim - hhj - 0.5
                j_at_xedge = abs(xj) >= x_lim - hwj - 0.5

                overlap_x = (hwi + hwj + box_gap) - abs(xi - xj)
                overlap_y = (hhi + hhj + box_gap) - abs(yi - yj)
                if overlap_x > 0 && overlap_y > 0
                    any_overlap = true
                    force_x = (i_at_ytop || j_at_ytop)
                    force_y = (i_at_xedge || j_at_xedge) && !force_x
                    resolve_x = force_x || (!force_y && overlap_x <= overlap_y)

                    if resolve_x
                        sx  = xi >= xj ? 1.0 : -1.0
                        gap = overlap_x
                        if i_at_xedge && !j_at_xedge
                            dx_acc[j] -= gap * sx;  wt[j] += 1.0
                        elseif j_at_xedge && !i_at_xedge
                            dx_acc[i] += gap * sx;  wt[i] += 1.0
                        else
                            dx_acc[i] += (gap / 2) * sx;  wt[i] += 1.0
                            dx_acc[j] -= (gap / 2) * sx;  wt[j] += 1.0
                        end
                    else
                        sy  = yi >= yj ? 1.0 : -1.0
                        gap = overlap_y
                        if i_at_ytop && !j_at_ytop
                            dy_acc[j] -= gap * sy;  wt[j] += 1.0
                        elseif j_at_ytop && !i_at_ytop
                            dy_acc[i] += gap * sy;  wt[i] += 1.0
                        else
                            dy_acc[i] += (gap / 2) * sy;  wt[i] += 1.0
                            dy_acc[j] -= (gap / 2) * sy;  wt[j] += 1.0
                        end
                    end
                end
            end
        end

        !any_overlap && break

        # Apply accumulated displacements with light damping to avoid overshoot.
        # Do NOT divide by wt: summing all pair contributions and damping gives
        # faster convergence than averaging for clustered multi-body overlaps.
        for i in 1:n
            if wt[i] > 0
                positions[i] = (positions[i][1] + 0.8 * dx_acc[i],
                                positions[i][2] + 0.8 * dy_acc[i])
            end
        end
        fill!(dx_acc, 0.0); fill!(dy_acc, 0.0); fill!(wt, 0.0)
    end
end


# Redistribute logos that are angularly bunched around the map center.
# Logos whose angular arc gap (at their boundary radius) is smaller than their
# combined half-widths + gap get nudged apart.  Re-places each moved logo at the
# correct boundary distance after adjusting its direction.  Jacobi-style: all
# angle adjustments are computed from the state at the start of each pass.
function angular_spread!(
    positions::Vector{Tuple{Float64,Float64}},
    logo_sizes::Vector{Tuple{Float64,Float64}},
    anchors::Vector{LogoAnchor},
    map_boundary::MapBoundary;
    logo_gap::Float64 = 5.0,
    gap_factor::Float64 = 1.2,  # require gap_factor * (hw_i + hw_j + logo_gap) arc gap
    max_passes::Int = 300,
)
    n = length(positions)
    n <= 1 && return

    for _ in 1:max_passes
        radii  = [sqrt(positions[i][1]^2 + positions[i][2]^2) for i in 1:n]
        angles = [atan(positions[i][2], positions[i][1]) for i in 1:n]
        order  = sortperm(angles)

        any_move = false
        da_acc = zeros(Float64, n)

        for k in 1:n
            i = order[k]
            j = order[k == n ? 1 : k + 1]

            # Signed angular gap from i to j (always in [0, 2π])
            da = angles[j] - angles[i]
            while da < 0;   da += 2π; end
            while da > 2π;  da -= 2π; end

            r_mid = (radii[i] + radii[j]) / 2
            r_mid < 1.0 && continue

            hw_i = logo_sizes[i][1] / 2
            hw_j = logo_sizes[j][1] / 2
            needed = gap_factor * (hw_i + hw_j + logo_gap) / r_mid

            if da < needed
                push = (needed - da) / 2
                da_acc[i] -= push
                da_acc[j] += push
                any_move = true
            end
        end

        !any_move && break

        # Apply accumulated angle adjustments and re-place at boundary.
        for i in 1:n
            abs(da_acc[i]) < 1e-9 && continue
            new_a = angles[i] + da_acc[i]
            nx, ny = cos(new_a), sin(new_a)
            hw = logo_sizes[i][1] / 2
            hh = logo_sizes[i][2] / 2
            t  = boundary_push_distance(nx, ny, map_boundary, logo_gap, hw, hh)
            positions[i] = (t * nx, t * ny)
        end
    end
end

# Clamp all logos to canvas margins without applying the boundary push.
# Used during cleanup so logos can slide laterally along the map perimeter
# to resolve multi-body overlaps, without being snapped back to their
# canonical dot-direction positions on every iteration.
function canvas_clamp!(
    positions::Vector{Tuple{Float64,Float64}},
    logo_sizes::Vector{Tuple{Float64,Float64}};
    canvas_margin::Float64=8.0,
    fig_x_min::Float64=-300.0,
    fig_x_max::Float64=300.0,
    fig_y_min::Float64=-146.0,
    fig_y_max::Float64=146.0,
)
    for i in eachindex(positions)
        x, y = positions[i]
        hw = logo_sizes[i][1] / 2
        hh = logo_sizes[i][2] / 2
        x = clamp(x, fig_x_min + hw + canvas_margin, fig_x_max - hw - canvas_margin)
        y = clamp(y, fig_y_min + hh + canvas_margin, fig_y_max - hh - canvas_margin)
        positions[i] = (x, y)
    end
end

function layout_logos(
    anchors::Vector{LogoAnchor},
    map_boundary::MapBoundary;
    spring_k::Float64=0.5,
    repulse_k::Float64=500.0,
    boundary_k::Float64=20.0,
    n_iter::Int=500,
    dt::Float64=0.1,
    logo_gap::Float64=5.0,
    box_gap::Float64=15.0,
    fig_x_min::Float64=-300.0,
    fig_x_max::Float64=300.0,
    fig_y_min::Float64=-146.0,
    fig_y_max::Float64=146.0,
)::Vector{Tuple{Float64,Float64}}
    if isempty(anchors)
        return Tuple{Float64,Float64}[]
    end

    positions = initialize_positions(anchors;
        x_fig_min=fig_x_min, x_fig_max=fig_x_max,
        y_fig_min=fig_y_min, y_fig_max=fig_y_max,
    )
    logo_sizes = [a.logo_size for a in anchors]
    state = LogoState(positions, anchors)

    # Push any logos that initialised inside the map out before the simulation.
    enforce_margin_boundary!(state.positions, logo_sizes, anchors, map_boundary;
        logo_gap=logo_gap,
        fig_x_min=fig_x_min, fig_x_max=fig_x_max,
        fig_y_min=fig_y_min, fig_y_max=fig_y_max,
    )

    # Maximum displacement per step scales with the coordinate space.
    max_step = 10.0 * (fig_x_max / 300.0)

    current_dt = dt
    for _ in 1:n_iter
        uncross_positions!(state.positions, state.anchors)
        forces = compute_forces(
            state, map_boundary;
            spring_k=spring_k, repulse_k=repulse_k,
            boundary_k=boundary_k, logo_gap=logo_gap,
            fig_x_min=fig_x_min, fig_x_max=fig_x_max,
            fig_y_min=fig_y_min, fig_y_max=fig_y_max,
        )
        state.positions = map(eachindex(state.positions)) do i
            dx = current_dt * forces[i][1]
            dy = current_dt * forces[i][2]
            step = sqrt(dx^2 + dy^2)
            if step > max_step
                dx *= max_step / step
                dy *= max_step / step
            end
            (state.positions[i][1] + dx, state.positions[i][2] + dy)
        end
        # Hard constraint: no logo may enter the map regardless of force magnitude.
        enforce_margin_boundary!(state.positions, logo_sizes, anchors, map_boundary;
            logo_gap=logo_gap,
            fig_x_min=fig_x_min, fig_x_max=fig_x_max,
            fig_y_min=fig_y_min, fig_y_max=fig_y_max,
        )
        current_dt *= 0.99
    end

    # Angular spreading: redistribute logos that are bunched in the same angular
    # region around the map center (e.g. many N. American + European institutions
    # all pointing roughly northward).  This runs after physics so it starts from
    # a physically-motivated state, then spreads logos that are still too close
    # in angle.  enforce_margin_boundary! follows to keep logos outside the map.
    angular_spread!(state.positions, logo_sizes, anchors, map_boundary;
        logo_gap=logo_gap)
    enforce_margin_boundary!(state.positions, logo_sizes, anchors, map_boundary;
        logo_gap=logo_gap,
        fig_x_min=fig_x_min, fig_x_max=fig_x_max,
        fig_y_min=fig_y_min, fig_y_max=fig_y_max,
    )
    canvas_clamp!(state.positions, logo_sizes;
        fig_x_min=fig_x_min, fig_x_max=fig_x_max,
        fig_y_min=fig_y_min, fig_y_max=fig_y_max,
    )

    # Post-physics cleanup.
    #
    # Key insight: geographically close institutions (e.g. NY/CH/TOR, LON/PAR/BER)
    # have nearly identical dot directions, so enforce_margin_boundary! places their
    # logos at almost the same position.  If we call enforce inside the separation
    # loop, it resets logos to these canonical positions every iteration, undoing
    # any x-separation achieved by separate_overlapping!.
    #
    # Fix: during the cleanup loop, use canvas_clamp! (bounds only, no boundary
    # push).  This lets logos slide laterally along the map perimeter to resolve
    # multi-body overlaps.  Full enforce is called only at the end, after
    # separation has converged.  A final round of separation handles any residual
    # overlaps introduced by the last enforce call.
    _sep_kwargs = (box_gap=box_gap, canvas_margin=8.0,
                   fig_x_min=fig_x_min, fig_x_max=fig_x_max,
                   fig_y_min=fig_y_min, fig_y_max=fig_y_max)
    _clamp_kwargs = (canvas_margin=8.0,
                     fig_x_min=fig_x_min, fig_x_max=fig_x_max,
                     fig_y_min=fig_y_min, fig_y_max=fig_y_max)
    _enf_kwargs = (logo_gap=logo_gap, canvas_margin=8.0,
                   fig_x_min=fig_x_min, fig_x_max=fig_x_max,
                   fig_y_min=fig_y_min, fig_y_max=fig_y_max)

    for _ in 1:100
        separate_overlapping!(state.positions, logo_sizes; max_iter=200, _sep_kwargs...)
        canvas_clamp!(state.positions, logo_sizes; _clamp_kwargs...)
        uncross_positions!(state.positions, state.anchors; max_passes=20)
        canvas_clamp!(state.positions, logo_sizes; _clamp_kwargs...)
    end
    # Final cleanup sequence.
    #
    # The canvas_clamp! loop above has already separated logos.  We now do ONE
    # full enforce to push any logos that drifted inside the map back to their
    # canonical boundary positions.  For geographically close cities (NY/TOR/CH,
    # LON/PAR/BER) the canonical positions may overlap — the subsequent
    # separate resolves those overlaps.  We then use canvas_clamp! rather than
    # another enforce so that the overlap resolution is not immediately undone.
    # Logos left slightly inside the map's exclusion zone are accepted: the minor
    # visual cost (logo very slightly over the map edge) is preferable to two
    # logos drawn on top of each other.
    enforce_margin_boundary!(state.positions, logo_sizes, anchors, map_boundary; _enf_kwargs...)
    separate_overlapping!(state.positions, logo_sizes; max_iter=2000, _sep_kwargs...)
    canvas_clamp!(state.positions, logo_sizes; _clamp_kwargs...)
    uncross_positions!(state.positions, state.anchors; max_passes=500)
    canvas_clamp!(state.positions, logo_sizes; _clamp_kwargs...)

    return state.positions
end
