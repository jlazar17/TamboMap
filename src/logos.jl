using FileIO
using Downloads

function _sniff_extension(path::String)::String
    bytes = open(path) do f; read(f, 12); end
    length(bytes) >= 4 || return ".bin"
    bytes[1:4] == UInt8[0x89, 0x50, 0x4E, 0x47] && return ".png"
    bytes[1:3] == UInt8[0xFF, 0xD8, 0xFF]        && return ".jpg"
    bytes[1:4] == UInt8[0x47, 0x49, 0x46, 0x38]  && return ".gif"
    length(bytes) >= 12 &&
        bytes[1:4]  == UInt8[0x52,0x49,0x46,0x46] &&
        bytes[9:12] == UInt8[0x57,0x45,0x42,0x50] && return ".webp"
    # SVG: look for "<svg" in the first 512 bytes of text
    text = String(open(path) do f; read(f, 512); end)
    occursin("<svg", text) && return ".svg"
    return ".bin"
end

function _svg_to_png(svg_path::String, png_path::String; height::Int=1024)
    rsvg = Sys.which("rsvg-convert")
    rsvg === nothing && error("rsvg-convert not found; install librsvg (brew install librsvg) to use SVG logos")
    run(`$rsvg -h $height -f png -o $png_path $svg_path`)
end

function _imagemagick_to_png(src::String, dest::String)
    convert = Sys.which("convert")
    convert === nothing && error("ImageMagick 'convert' not found; install it (brew install imagemagick) to use WebP/GIF logos")
    run(`$convert $src $dest`)
end

function download_logo(url::String, dest_path::String)
    mkpath(dirname(dest_path))
    tmp_raw = tempname()
    Downloads.download(url, tmp_raw)
    ext = _sniff_extension(tmp_raw)
    ext == ".bin" && error("Unrecognised image format for URL: $url")
    tmp = tmp_raw * ext
    mv(tmp_raw, tmp)
    if ext == ".svg"
        _svg_to_png(tmp, dest_path)
        rm(tmp)
    elseif ext in (".webp", ".gif")
        _imagemagick_to_png(tmp, dest_path)
        rm(tmp)
    else
        # PNG or JPG: load and re-save to normalise to PNG
        img = FileIO.load(tmp)
        rm(tmp)
        FileIO.save(dest_path, img)
    end
end

function _load_logo(path::String)
    return rotr90(FileIO.load(path))
end

function get_logo(inst::Institution; cache_dir::String="logo_cache")
    if inst.logo_path !== nothing && isfile(inst.logo_path)
        if lowercase(splitext(inst.logo_path)[2]) == ".svg"
            mkpath(cache_dir)
            sanitized = replace(lowercase(inst.name), r"[^a-z0-9]" => "_")
            dest = joinpath(cache_dir, "$(sanitized).png")
            isfile(dest) || _svg_to_png(inst.logo_path, dest)
            return _load_logo(dest)
        end
        return _load_logo(inst.logo_path)
    elseif inst.logo_url !== nothing
        sanitized = replace(lowercase(inst.name), r"[^a-z0-9]" => "_")
        dest = joinpath(cache_dir, "$(sanitized).png")
        if !isfile(dest)
            download_logo(inst.logo_url, dest)
        end
        return _load_logo(dest)
    else
        return nothing
    end
end
