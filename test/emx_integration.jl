@testmodule TestData begin
    using EnergyModelsBase
    using HiGHS
    using JuMP
    using TimeStruct
    using EnergyModelsHeat

    # Define the different resources and their emission intensity in tCO2/MWh
    power    = ResourceCarrier("Power", 0.0)
    heat_sur = EnergyModelsHeat.Heat("surplus_heat", 80, 60)
    heat_use = EnergyModelsHeat.Heat("useable_heat", 80, 40)

    CO₂      = ResourceEmit("CO₂", 1.0)
    products = [power, heat_sur, heat_use, CO₂]

    pinch_data = PinchData(
        FixedProfile(80),    # PEM FC
        FixedProfile(60),
        FixedProfile(8),     # Depends on size of heat exchanger (Ask Davide?)
        FixedProfile(80),    # 80-90°C at Isfjord Radio according to schematics
        FixedProfile(40),    # ca 40°C depending on load according to schematics
    )

    function generate_data()
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
                "surplus heat source",      # Node id
                FixedProfile(0.85),         # Capacity in MW
                FixedProfile(0),            # Variable OPEX in EUR/MW
                FixedProfile(0),            # Fixed OPEX in EUR/8h
                Dict(heat_sur => 1),        # Output from the Node, in this gase, heat_sur
            ),
            HeatExchanger(
                "heat exchanger",
                FixedProfile(1.0),
                FixedProfile(0),
                FixedProfile(0),
                Dict(heat_sur => 1),
                Dict(heat_use => 1),
                [pinch_data],
            ),
            RefSink(
                "heat demand",              # Node id
                OperationalProfile([0.2, 0.3, 0.4, 0.3]), # Demand in MW
                Dict(:surplus => FixedProfile(1e6), :deficit => FixedProfile(1e6)),
                # Line above: Surplus and deficit penalty for the node in EUR/MWh
                Dict(heat_use => 1),           # Energy demand and corresponding ratio
            ),
        ]

        # Connect all nodes with the availability node for the overall energy/mass balance
        links = [
            Direct("source-exchange", nodes[1], nodes[2], Linear()),
            Direct("exchange-demand", nodes[2], nodes[3], Linear()),
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

    function generate_upgrade_data()
        # Base case
        case, model, nodes, products, T = TestData.generate_data()

        # Define upgrade node
        heat_upgrade = EnergyModelsHeat.DirectHeatUpgrade(
            "heat upgrade",
            FixedProfile(1.0),
            FixedProfile(0),
            FixedProfile(0),
            Dict(heat_sur => 1, power => 1),
            Dict(heat_use => 1),
            [pinch_data],
        )
        power_source = RefSource(
            "power source",             # Node id
            FixedProfile(0.85),         # Capacity in MW
            FixedProfile(1.0),          # Variable OPEX in EUR/MW
            FixedProfile(0),            # Fixed OPEX in EUR
            Dict(power => 1),           # Output from the Node
        )

        heat_demand = RefSink(
            "heat demand",              # Node id
            OperationalProfile([0.2, 0.3, 0.4, 0.3]), # Demand in MW
            Dict(:surplus => FixedProfile(0), :deficit => FixedProfile(1e6)),
            # Line above: Surplus and deficit penalty for the node in EUR/MWh
            Dict(heat_use => 1),           # Energy demand and corresponding ratio
        )

        nodes[3] = heat_demand
        push!(nodes, heat_upgrade)
        push!(nodes, power_source)

        links = [
            Direct("source-upgrade", nodes[1], nodes[4], Linear()),
            Direct("power-upgrade", nodes[5], nodes[4], Linear()),
            Direct("upgrade-demand", nodes[4], nodes[3], Linear()),
        ]
        case[:nodes] = nodes
        case[:links] = links

        return (; case, model, nodes, products, T)
    end
end

@testitem "Simple EMX model" setup = [TestData] begin
    using JuMP
    using HiGHS
    using EnergyModelsBase
    using EnergyModelsHeat

    case, model, nodes, products, T = TestData.generate_data()
    optimizer = optimizer_with_attributes(HiGHS.Optimizer, MOI.Silent() => true)
    m = run_model(case, model, optimizer)

    surplus = products[2]
    usable = products[3]
    ratio = EnergyModelsHeat.ψ(80, 60, 8, 80, 40)

    # Test that ratio is calculated as expected
    @test ratio ≈ 0.3 atol = 0.01
    # Test that EMX model gives correct ratio of usable energy for all time periods
    for t ∈ T
        @test JuMP.value(m[:flow_out][nodes[1], t, surplus]) * ratio ≈
              JuMP.value(m[:flow_out][nodes[2], t, usable])
    end
end

@testitem "Simple Upgrade example" setup = [TestData] begin
    using JuMP
    using HiGHS
    using EnergyModelsBase
    using EnergyModelsHeat

    case, model, nodes, products, T = TestData.generate_upgrade_data()
    optimizer = optimizer_with_attributes(HiGHS.Optimizer, MOI.Silent() => true)

    m = run_model(case, model, optimizer)

    power = products[1]
    usable_heat = products[3]
    upgrade_node = nodes[4]
    surplus_source = nodes[1]

    pd = EnergyModelsHeat.pinch_data(upgrade_node)

    # Test that EMX model gives correct ratio of usable energy for all time periods
    for t ∈ T
        # Check that actual power flow matches specified fraction of upgraded output heat flow
        @test JuMP.value(m[:flow_in][upgrade_node, t, power]) ≈
              EnergyModelsHeat.upgrade_fraction(pd, t) *
              JuMP.value(m[:flow_out][upgrade_node, t, usable_heat])
    end
end
