@testitem "Examples" begin
    ENV["EMX_TEST"] = true # Set flag for example scripts to check if they are run as part of the tests
    exdir = joinpath(@__DIR__, "..", "examples")
    files = filter(endswith(".jl"), readdir(exdir))
    for file ∈ files
        @testset "Example $file" begin
            redirect_stdio(stdout = devnull, stderr = devnull) do
                include(joinpath(exdir, file))
                @test termination_status(m) == MOI.OPTIMAL
            end
        end
    end
    Pkg.activate(@__DIR__)
end
