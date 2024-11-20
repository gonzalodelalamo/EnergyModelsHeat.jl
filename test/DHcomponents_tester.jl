@testitem "Simple EMX DH model" begin
    using EnergyModelsBase
    using HiGHS
    using JuMP
    using TimeStruct
    using EnergyModelsHeat
    #using PrettyTables

    const EMH = EnergyModelsHeat

    function generate_data()

        # Define the different resources and their emission intensity in tCO2/MWh
        dh_heat  = ResourceHeat("DHheat", 0.0, 70.0)
        CO₂      = ResourceEmit("CO₂", 0.0)
        products = [dh_heat]

        op_duration = 2 # Each operational period has a duration of 2
        op_number = 4   # There are in total 4 operational periods
        operational_periods = SimpleTimes(op_number, op_duration)

        op_per_strat = op_duration * op_number

        # Creation of the time structure and global data
        T = TwoLevel(2, 1, operational_periods; op_per_strat)
        model = OperationalModel(
            Dict(CO₂ => FixedProfile(10)),  # Emission cap for CO₂ in t/8h
            Dict(CO₂ => FixedProfile(0)),   # Emission price for CO₂ in EUR/t
            CO₂,                            # CO₂ instance
        )

        # Create the individual test nodes for a system with 
        # 1) a heat surplus source
        # 2) a heat conversion from surplus to usable heat
        # 3) a heat sink representing the district heating demand
        nodes = [
            RefSource(
                "heat source",      # Node id
                FixedProfile(0.85),         # Capacity in MW
                FixedProfile(0),            # Variable OPEX in EUR/MW
                FixedProfile(0),            # Fixed OPEX in EUR/8h
                Dict(dh_heat => 1),        # Output from the Node, in this gase, dh_heat
            ),
            RefSink(
                "heat demand",              # Node id
                OperationalProfile([0.2, 0.3, 0.4, 0.3]), # Demand in MW
                Dict(:surplus => FixedProfile(0), :deficit => FixedProfile(1e6)),
                # Line above: Surplus and deficit penalty for the node in EUR/MWh
                Dict(dh_heat => 1),           # Energy demand and corresponding ratio
            ),
        ]

        # Connect all nodes with the availability node for the overall energy/mass balance
        links = [
            EMH.DHPipe("DH pipe 1", nodes[1], nodes[2], 1000.0, 4.0, 10.0, dh_heat),
        ]

        # WIP data structure
        case = Dict(
            :nodes => nodes,
            :links => links,
            :products => products,
            :T => T,
        )
        return (; case, model, nodes, products, T)
    end
    case, model, nodes, products, T = generate_data()
    optimizer = optimizer_with_attributes(HiGHS.Optimizer, MOI.Silent() => true)
    m = run_model(case, model, optimizer)

    # Display some results
    source, sink = case[:nodes]

    
    # TODO: sjekk at varmetapet er innen ok range
        # Initialize variables for accumulation
    heat_supply = 0.0
    heat_delivered = 0.0

    # Calculate total power uptake and heat delivered over all time periods
    for t ∈ T
        heat_supply += JuMP.value(m[:flow_in][nodes[1], t, dh_heat])
        heat_delivered += JuMP.value(m[:flow_out][nodes[2], t, dh_heat])
    end

    heat_loss = heat_supply - heat_delivered

    heat_loss_assumed = 0.03
    # Check the calculated relative heat loss
    calculated_loss = heat_loss/ heat_supply
    println(calculated_loss)
    @test heat_loss_assumed  ≈ calculated_loss atol = 0.1



end
