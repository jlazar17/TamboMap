struct Location
    country::String
    city::String
    longitude::Float64
    latitude::Float64
end

struct Institution
    name::String
    location::Location
end

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
    return Institution(d["name"], loc)
end
    
function institutions_from_json(dir::String)
    files = Glob.glob("$(dir)/*.json")
    return [institution_from_json(file) for file in files]
end
