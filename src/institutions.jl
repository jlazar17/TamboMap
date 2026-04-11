struct Location
    country::String
    city::String
    longitude::Float64
    latitude::Float64
end

struct Institution
    name::String
    location::Location
    logo_path::Union{String, Nothing}
    logo_url::Union{String, Nothing}
end

Institution(name::String, location::Location) = Institution(name, location, nothing, nothing)

function save_institution(institution::Institution, file::String)
    open(file, "w") do f
        write(f, JSON.json(institution))
    end
end

function save_institutions(institutions::Vector{Institution}, outdir::String)
    for institution in institutions
        filename = "$(outdir)/$(replace(lowercase(institution.name), " "=>"_")).json"
        TamboMap.save_institution(institution, filename)
    end
end

function institution_from_json(file::String)
    d = JSON.parsefile(file)
    loc = Location(
        d["location"]["country"],
        d["location"]["city"],
        d["location"]["latitude"],
        d["location"]["longitude"],
    )
    logo_path = get(d, "logo_path", nothing)
    logo_url = get(d, "logo_url", nothing)
    return Institution(d["name"], loc, logo_path, logo_url)
end
    
function institutions_from_json(dir::String)
    files = Glob.glob("*.json", dir)
    return [institution_from_json(file) for file in files]
end
