import XCTest
@testable import COCHelperCore

final class RoadmapPlannerTests: XCTestCase {
    private let planner = RoadmapPlanner()

    func testDemoKeepsCoreBuildingSequenceOnBuilderOne() {
        let plan = planner.makePlan(for: .demo)
        let coreNames = plan.builders[0].tasks.prefix(3).map(\.name)

        XCTAssertEqual(Array(coreNames), ["大本营", "实验室", "兵营"])
        XCTAssertEqual(plan.builders.count, 6)
    }

    func testLeagueReserveDelaysHeroUpgrades() {
        var input = PlannerInput.demo
        input.warMode = .league
        input.reserveHeroesDuringLeague = true

        let plan = planner.makePlan(for: input)
        let heroTasks = plan.builders.flatMap(\.tasks).filter { $0.category == .hero }

        XCTAssertFalse(heroTasks.isEmpty)
        XCTAssertTrue(heroTasks.allSatisfy { $0.startDay >= 7 })
    }

    func testResearchQueueIsSequential() {
        let plan = planner.makePlan(for: .demo)

        for pair in zip(plan.research, plan.research.dropFirst()) {
            XCTAssertGreaterThanOrEqual(pair.1.startDay, pair.0.endDay)
        }
    }

    func testSingleBuilderInputDoesNotCrash() {
        var input = PlannerInput.demo
        input.builderCount = 1

        let plan = planner.makePlan(for: input)

        XCTAssertEqual(plan.builders.count, 1)
        XCTAssertGreaterThan(plan.metrics.plannedTaskCount, 0)
    }

    func testTownHallReadinessCreatesVisibleGuardrail() {
        var input = PlannerInput.demo
        input.nextTownHallReadiness = .notReady

        let plan = planner.makePlan(for: input)
        let townHall = plan.builders.flatMap(\.tasks).first { $0.category == .townHall }

        XCTAssertEqual(townHall?.startDay, 14)
        XCTAssertTrue(plan.insights.contains { $0.title == "暂缓下一大本" })
    }

    func testBuilderRemainingTimeMovesCoreQueueStart() {
        let input = PlannerInput(
            townHallLevel: 15,
            builderCount: 1,
            researchRemainingDays: 0,
            horizon: .days30,
            checkInFrequency: .once,
            warMode: .relaxed,
            reserveHeroesDuringLeague: false,
            avoidResourceOverflow: false,
            magicItemsAvailable: false,
            nextTownHallReadiness: .ready,
            builderStates: [BuilderState(id: 1, currentTaskName: "防御", remainingDays: 4)],
            resourceInventory: .demo,
            heroStatuses: HeroStatus.demo,
            gameDataCatalog: .demo,
            tasks: [UpgradeTask(name: "大本营", category: .townHall, durationDays: 3, resource: .gold, track: .core, estimatedCost: 1_000_000)],
            researchTasks: []
        )

        let plan = planner.makePlan(for: input)

        XCTAssertEqual(plan.builders[0].tasks.first?.startDay, 4)
    }

    func testInsufficientInventoryUsesDailyIncomeInsteadOfIgnoringCost() {
        let inventory = ResourceInventory(
            gold: ResourceStock(current: 0, capacity: 10_000_000, dailyIncome: 1_000_000),
            elixir: ResourceStock(current: 10_000_000, capacity: 20_000_000, dailyIncome: 0),
            darkElixir: ResourceStock(current: 100_000, capacity: 350_000, dailyIncome: 0)
        )
        let input = PlannerInput(
            townHallLevel: 15,
            builderCount: 1,
            researchRemainingDays: 0,
            horizon: .days30,
            checkInFrequency: .once,
            warMode: .relaxed,
            reserveHeroesDuringLeague: false,
            avoidResourceOverflow: false,
            magicItemsAvailable: false,
            nextTownHallReadiness: .ready,
            builderStates: [BuilderState(id: 1)],
            resourceInventory: inventory,
            heroStatuses: HeroStatus.demo,
            gameDataCatalog: .demo,
            tasks: [UpgradeTask(name: "昂贵防御", category: .defense, durationDays: 2, resource: .gold, track: .defense, estimatedCost: 5_000_000)],
            researchTasks: []
        )

        let plan = planner.makePlan(for: input)
        let task = plan.builders[0].tasks.first

        XCTAssertEqual(task?.startDay, 5)
        XCTAssertTrue(task?.note?.contains("等待资源库存") == true)
        XCTAssertEqual(plan.metrics.resourceBlockedCount, 0)
    }

    func testHeroAvailabilityWindowDelaysHeroUpgrade() {
        let input = PlannerInput(
            townHallLevel: 15,
            builderCount: 1,
            researchRemainingDays: 0,
            horizon: .days30,
            checkInFrequency: .once,
            warMode: .relaxed,
            reserveHeroesDuringLeague: false,
            avoidResourceOverflow: false,
            magicItemsAvailable: false,
            nextTownHallReadiness: .ready,
            builderStates: [BuilderState(id: 1)],
            resourceInventory: .demo,
            heroStatuses: [HeroStatus(name: "女王", level: 80, warProtectedUntilDay: 12)],
            gameDataCatalog: .demo,
            tasks: [UpgradeTask(name: "女王", category: .hero, durationDays: 3, resource: .darkElixir, track: .hero, estimatedCost: 50_000)],
            researchTasks: []
        )

        let plan = planner.makePlan(for: input)
        let task = plan.builders[0].tasks.first

        XCTAssertEqual(task?.startDay, 12)
        XCTAssertTrue(task?.note?.contains("英雄出战窗口保护") == true)
    }

    func testCatalogDetectsDuplicateEntryKeys() {
        var catalog = GameDataCatalog.demo
        catalog.entries.append(catalog.entries[0])

        XCTAssertFalse(catalog.status.isStructurallyValid)
    }

    func testLegacyPlannerInputDecodesWithNewDefaults() throws {
        let legacyJSON = """
        {
          "townHallLevel": 15,
          "builderCount": 1,
          "researchRemainingDays": 0,
          "horizon": 30,
          "checkInFrequency": 1,
          "warMode": "relaxed",
          "reserveHeroesDuringLeague": false,
          "avoidResourceOverflow": true,
          "magicItemsAvailable": false,
          "nextTownHallReadiness": "ready",
          "tasks": [{
            "id": "00000000-0000-0000-0000-000000000001",
            "name": "旧任务",
            "category": "building",
            "durationDays": 2,
            "resource": "gold",
            "priority": 50,
            "warImpact": "medium",
            "track": "core",
            "isRepeatable": false
          }],
          "researchTasks": []
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(PlannerInput.self, from: legacyJSON)

        XCTAssertEqual(decoded.tasks.first?.name, "旧任务")
        XCTAssertEqual(decoded.builderStates.count, 6)
        XCTAssertEqual(decoded.gameDataCatalog.catalogVersion, "demo-0.1")
        XCTAssertEqual(decoded.resourceInventory.gold.current, ResourceInventory.demo.gold.current)
    }

    func testEmptyPlannerInputDoesNotReuseDemoAccountState() {
        let input = PlannerInput.empty

        XCTAssertTrue(input.tasks.isEmpty)
        XCTAssertTrue(input.researchTasks.isEmpty)
        XCTAssertTrue(input.heroStatuses.isEmpty)
        XCTAssertEqual(input.resourceInventory.gold.current, 0)
        XCTAssertEqual(input.resourceInventory.elixir.current, 0)
        XCTAssertEqual(input.resourceInventory.darkElixir.current, 0)
        XCTAssertTrue(input.builderStates.allSatisfy(\.isAvailable))
    }

    func testVillageProfileRoundTripsItsOwnPlannerInputAndSnapshot() throws {
        let snapshot = try AccountSnapshotImporter.parse(
            "{\"tag\":\"#VILLAGE1\",\"buildings\":[]}",
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        var input = PlannerInput.empty
        input.horizon = .days180
        let profile = VillageProfile(name: "主村", input: input, accountSnapshot: snapshot)

        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(VillageProfile.self, from: data)

        XCTAssertEqual(decoded.name, "主村")
        XCTAssertEqual(decoded.input.horizon, .days180)
        XCTAssertEqual(decoded.accountSnapshot?.tag, "#VILLAGE1")
    }
}
