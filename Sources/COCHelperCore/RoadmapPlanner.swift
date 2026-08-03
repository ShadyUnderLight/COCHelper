import Foundation

public struct RoadmapPlanner: Sendable {
    private struct ResolvedTask: Sendable {
        let taskID: UUID
        let name: String
        let category: UpgradeCategory
        let resource: ResourceClass
        let cost: Int
        let durationDays: Double
        let priority: Int
        let dataKey: String?
    }

    public init() {}

    public func makePlan(for input: PlannerInput) -> RoadmapPlan {
        let horizon = input.horizon.days
        let step = input.checkInFrequency.schedulingStep
        let builderCount = min(6, max(1, input.builderCount))
        let catalog = input.gameDataCatalog

        let research = makeResearchPlan(input: input, horizon: horizon, step: step)
        var plannedResourceTasks = research

        var lanes = (0..<builderCount).map { index in
            BuilderPlan(builderIndex: index + 1, title: "工人 " + String(index + 1), role: roleName(for: index), tasks: [])
        }
        let stateByID = Dictionary(uniqueKeysWithValues: input.builderStates.map { ($0.id, $0) })
        var laneAvailable = (0..<builderCount).map { index in
            max(0, stateByID[index + 1]?.remainingDays ?? 0)
        }
        var plannedBuilderTasks: [PlannedTask] = []
        var resourceBlockedCount = research.filter { $0.note?.contains("库存不足") == true }.count

        let builderTasks = input.tasks
            .filter { $0.category != .research }
            .flatMap { expand($0, horizon: horizon) }
            .sorted { lhs, rhs in
                let lhsRank = categoryRank(lhs.category)
                let rhsRank = categoryRank(rhs.category)
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
                return lhs.name < rhs.name
            }

        for task in builderTasks {
            let resolved = resolve(task, catalog: catalog, step: step)
            let laneIndex = chooseLane(for: task, laneAvailable: laneAvailable, builderCount: builderCount)
            let townHallDelay = townHallStartDelay(for: input.nextTownHallReadiness, category: task.category)
            let heroDelay = heroStartDelay(for: task, input: input)
            let trackDelay = max(townHallDelay, heroDelay)
            let staggerDelay = input.avoidResourceOverflow ? Double(laneIndex % 3) * step : 0
            let earliest = max(laneAvailable[laneIndex], trackDelay, staggerDelay)

            var start = snap(earliest, to: step)
            let duration = max(step, resolved.durationDays)
            var end = start + duration
            var inventoryDelayed = false
            var resourceDelayed = false
            var finishDelayed = false

            let inventoryResult = resourceReadyDay(
                for: resolved.resource,
                cost: resolved.cost,
                proposedDay: start,
                input: input,
                existing: plannedResourceTasks,
                horizon: horizon,
                step: step
            )
            if inventoryResult.day > start + 0.01 {
                start = inventoryResult.day
                end = start + duration
                inventoryDelayed = true
                resourceBlockedCount += inventoryResult.isBlocked ? 1 : 0
            }

            if input.avoidResourceOverflow {
                var attempts = 0
                while resourceOverlap(for: resolved.resource, start: start, end: end, in: plannedResourceTasks) >= resourceLimit(for: resolved.resource), attempts < 100 {
                    start = snap(start + step, to: step)
                    end = start + duration
                    resourceDelayed = true
                    attempts += 1
                }
            }

            var finishAttempts = 0
            while finishCollision(at: end, in: plannedBuilderTasks, tolerance: step * 0.6), finishAttempts < 100 {
                start = snap(start + step, to: step)
                end = start + duration
                finishDelayed = true
                finishAttempts += 1
            }

            let note = makeNote(
                for: task,
                start: start,
                inventoryDelayed: inventoryDelayed,
                resourceDelayed: resourceDelayed,
                finishDelayed: finishDelayed,
                townHallDelay: townHallDelay,
                heroDelay: heroDelay,
                inventoryBlocked: inventoryResult.isBlocked
            )
            let planned = PlannedTask(
                sourceTaskID: resolved.taskID,
                name: resolved.name,
                category: resolved.category,
                resource: resolved.resource,
                startDay: start,
                endDay: end,
                durationDays: duration,
                cost: resolved.cost,
                dataKey: resolved.dataKey,
                note: note,
                isDeferred: start > 0.01
            )
            plannedBuilderTasks.append(planned)
            plannedResourceTasks.append(planned)
            laneAvailable[laneIndex] = end
            lanes[laneIndex] = BuilderPlan(
                builderIndex: lanes[laneIndex].builderIndex,
                title: lanes[laneIndex].title,
                role: lanes[laneIndex].role,
                tasks: lanes[laneIndex].tasks + [planned]
            )
        }

        let metrics = makeMetrics(
            input: input,
            builders: lanes,
            research: research,
            plannedBuilderTasks: plannedBuilderTasks,
            resourceBlockedCount: resourceBlockedCount,
            catalog: catalog
        )
        let insights = makeInsights(
            input: input,
            metrics: metrics,
            research: research,
            catalog: catalog
        )

        return RoadmapPlan(
            horizonDays: input.horizon.rawValue,
            builders: lanes,
            research: research,
            metrics: metrics,
            insights: insights,
            dataLayer: catalog.status
        )
    }

    private func expand(_ task: UpgradeTask, horizon: Double) -> [UpgradeTask] {
        guard task.isRepeatable else { return [task] }

        let targetCount = min(48, max(8, Int(ceil(horizon / max(task.durationDays, 0.5)))))
        return (0..<targetCount).map { _ in task }
    }

    private func resolve(_ task: UpgradeTask, catalog: GameDataCatalog, step: Double) -> ResolvedTask {
        let entry = catalog.entry(for: task.dataKey)
        return ResolvedTask(
            taskID: task.id,
            name: task.name,
            category: task.category,
            resource: task.resource == .none ? (entry?.resource ?? .none) : task.resource,
            cost: task.estimatedCost > 0 ? task.estimatedCost : (entry?.cost ?? 0),
            durationDays: max(step, task.durationDays > 0 ? task.durationDays : (entry?.defaultDurationDays ?? step)),
            priority: task.priority,
            dataKey: task.dataKey
        )
    }

    private func categoryRank(_ category: UpgradeCategory) -> Int {
        switch category {
        case .townHall: 0
        case .building: 1
        case .hero: 2
        case .defense: 3
        case .resource: 4
        case .wall: 5
        case .trap: 6
        case .research: 7
        }
    }

    private func roleName(for index: Int) -> String {
        switch index {
        case 0: "核心建筑"
        case 1: "英雄轮换"
        case 2: "关键防御"
        case 3: "城墙与资源"
        case 4: "陷阱与机动"
        default: "长期英雄"
        }
    }

    private func preferredLanes(for task: UpgradeTask, builderCount: Int) -> [Int] {
        let last = max(0, builderCount - 1)
        let fallback = Array(0..<builderCount)
        let track = task.track == .automatic ? automaticTrack(for: task.category) : task.track

        switch track {
        case .core: return [0]
        case .hero: return [min(1, last)]
        case .defense: return [min(2, last)]
        case .flex: return [min(3, last)]
        case .traps: return [min(4, last)]
        case .longTermHero: return [min(5, last)]
        case .automatic: return fallback
        }
    }

    private func automaticTrack(for category: UpgradeCategory) -> BuilderTrack {
        switch category {
        case .townHall, .building: .core
        case .hero: .hero
        case .defense: .defense
        case .resource, .wall: .flex
        case .trap: .traps
        case .research: .automatic
        }
    }

    private func chooseLane(for task: UpgradeTask, laneAvailable: [Double], builderCount: Int) -> Int {
        let preferred = preferredLanes(for: task, builderCount: builderCount)
        return preferred.min { lhs, rhs in
            if laneAvailable[lhs] != laneAvailable[rhs] {
                return laneAvailable[lhs] < laneAvailable[rhs]
            }
            return lhs < rhs
        } ?? 0
    }

    private func townHallStartDelay(for readiness: TownHallReadiness, category: UpgradeCategory) -> Double {
        guard category == .townHall else { return 0 }
        switch readiness {
        case .ready: return 0
        case .nearlyReady: return 7
        case .notReady: return 14
        }
    }

    private func heroStartDelay(for task: UpgradeTask, input: PlannerInput) -> Double {
        guard task.category == .hero else { return 0 }
        let matchingStatus = input.heroStatuses.first { status in
            task.name.contains(status.name) || status.name.contains(task.name)
        }
        let explicitDelay = matchingStatus?.nextUpgradeAvailableDay ?? 0
        let leagueDelay = input.reserveHeroesDuringLeague && input.warMode == .league ? 7.0 : 0
        return max(explicitDelay, leagueDelay)
    }

    private func snap(_ value: Double, to step: Double) -> Double {
        guard step > 0 else { return value }
        return ceil((value - 0.000001) / step) * step
    }

    private func resourceLimit(for resource: ResourceClass) -> Int {
        switch resource {
        case .darkElixir: 1
        case .gold, .elixir, .mixed, .none: 2
        }
    }

    private func resourceOverlap(for resource: ResourceClass, start: Double, end: Double, in tasks: [PlannedTask]) -> Int {
        guard resource != .none else { return 0 }
        return tasks.filter {
            $0.resource == resource && $0.startDay < end && $0.endDay > start
        }.count
    }

    private func resourceReadyDay(
        for resource: ResourceClass,
        cost: Int,
        proposedDay: Double,
        input: PlannerInput,
        existing: [PlannedTask],
        horizon: Double,
        step: Double
    ) -> (day: Double, isBlocked: Bool) {
        guard resource != .none, cost > 0, let stock = input.resourceInventory.stock(for: resource) else {
            return (proposedDay, false)
        }

        var candidate = max(0, proposedDay)
        for _ in 0..<160 {
            let income = Double(stock.dailyIncome)
            let gross = min(Double(stock.capacity), Double(stock.current) + income * candidate)
            let spent = existing
                .filter { $0.resource == resource && $0.startDay <= candidate }
                .reduce(0) { $0 + $1.cost }
            let available = gross - Double(spent)
            if available >= Double(cost) {
                return (snap(candidate, to: step), false)
            }

            guard stock.dailyIncome > 0 else {
                return (horizon + max(1, step), true)
            }

            let shortage = Double(cost) - available
            let waitDays = max(step, ceil(shortage / income))
            candidate = snap(max(candidate + step, candidate + waitDays), to: step)
            if candidate > horizon + max(1, step) {
                return (candidate, true)
            }
        }
        return (horizon + max(1, step), true)
    }

    private func finishCollision(at end: Double, in tasks: [PlannedTask], tolerance: Double) -> Bool {
        tasks.contains { abs($0.endDay - end) < max(0.1, tolerance) }
    }

    private func makeNote(
        for task: UpgradeTask,
        start: Double,
        inventoryDelayed: Bool,
        resourceDelayed: Bool,
        finishDelayed: Bool,
        townHallDelay: Double,
        heroDelay: Double,
        inventoryBlocked: Bool
    ) -> String? {
        var notes: [String] = []
        if task.category == .townHall, townHallDelay > 0 {
            notes.append("等待大本营准备度")
        }
        if task.category == .hero, heroDelay > 0 {
            notes.append("英雄出战窗口保护")
        }
        if inventoryDelayed {
            notes.append(inventoryBlocked ? "库存不足，等待收入" : "等待资源库存")
        }
        if resourceDelayed {
            notes.append("资源错峰")
        }
        if finishDelayed {
            notes.append("避免同时完工")
        }
        if start > 0.01, notes.isEmpty {
            notes.append("按优先级错峰")
        }
        return notes.isEmpty ? nil : notes.joined(separator: " · ")
    }

    private func makeResearchPlan(input: PlannerInput, horizon: Double, step: Double) -> [PlannedTask] {
        var current = snap(input.researchRemainingDays, to: step)
        var result: [PlannedTask] = []

        let queue = input.researchTasks.sorted {
            if $0.priority != $1.priority { return $0.priority > $1.priority }
            return $0.name < $1.name
        }

        for task in queue {
            let resolved = resolveResearch(task, catalog: input.gameDataCatalog, step: step)
            let inventoryResult = resourceReadyDay(
                for: resolved.resource,
                cost: resolved.cost,
                proposedDay: current,
                input: input,
                existing: result,
                horizon: horizon,
                step: step
            )
            var start = max(current, inventoryResult.day)
            var resourceDelayed = start > current + 0.01

            if input.avoidResourceOverflow {
                var attempts = 0
                let duration = max(step, resolved.durationDays)
                while resourceOverlap(for: resolved.resource, start: start, end: start + duration, in: result) >= resourceLimit(for: resolved.resource), attempts < 100 {
                    start = snap(start + step, to: step)
                    resourceDelayed = true
                    attempts += 1
                }
            }

            let duration = max(step, resolved.durationDays)
            let end = start + duration
            var notes: [String] = []
            if current > 0 { notes.append("等待当前科技完成") }
            if resourceDelayed { notes.append(inventoryResult.isBlocked ? "库存不足，等待收入" : "等待资源库存") }
            if notes.isEmpty, start > 0.01 { notes.append("按优先级安排") }

            result.append(
                PlannedTask(
                    sourceTaskID: resolved.taskID,
                    name: resolved.name,
                    category: .research,
                    resource: resolved.resource,
                    startDay: start,
                    endDay: end,
                    durationDays: duration,
                    cost: resolved.cost,
                    dataKey: resolved.dataKey,
                    note: notes.isEmpty ? nil : notes.joined(separator: " · "),
                    isDeferred: start > 0
                )
            )
            current = end
            if current > horizon + max(step, duration) { break }
        }
        return result
    }

    private func resolveResearch(_ task: ResearchTask, catalog: GameDataCatalog, step: Double) -> ResolvedTask {
        let entry = catalog.entry(for: task.dataKey)
        return ResolvedTask(
            taskID: task.id,
            name: task.name,
            category: .research,
            resource: task.resource == .none ? (entry?.resource ?? .none) : task.resource,
            cost: task.estimatedCost > 0 ? task.estimatedCost : (entry?.cost ?? 0),
            durationDays: max(step, task.durationDays > 0 ? task.durationDays : (entry?.defaultDurationDays ?? step)),
            priority: task.priority,
            dataKey: task.dataKey
        )
    }

    private func makeMetrics(
        input: PlannerInput,
        builders: [BuilderPlan],
        research: [PlannedTask],
        plannedBuilderTasks: [PlannedTask],
        resourceBlockedCount: Int,
        catalog: GameDataCatalog
    ) -> PlanMetrics {
        let allTasks = plannedBuilderTasks + research
        let finishBuckets = Dictionary(grouping: allTasks) { Int(($0.endDay * 4).rounded()) }
        let collisionCount = finishBuckets.values.reduce(0) { $0 + max(0, $1.count - 1) }
        let peakResourceOverlap = peakOverlap(in: allTasks)
        let highFillResources = [ResourceClass.gold, .elixir, .darkElixir]
            .filter { input.resourceInventory.stock(for: $0)?.fillRatio ?? 0 >= 0.85 }
            .count
        let resourcePressure = min(
            100,
            collisionCount * 8
                + max(0, peakResourceOverlap - 2) * 12
                + highFillResources * 8
                + resourceBlockedCount * 20
                + (input.avoidResourceOverflow ? 0 : 12)
        )

        let hasHeroes = plannedBuilderTasks.contains { $0.category == .hero }
        let warFriendlyScore: Int
        if !hasHeroes {
            warFriendlyScore = 100
        } else {
            switch input.warMode {
            case .league where input.reserveHeroesDuringLeague: warFriendlyScore = 96
            case .warReady: warFriendlyScore = 84
            case .league: warFriendlyScore = 76
            case .relaxed: warFriendlyScore = 68
            }
        }

        let buildingEnd = plannedBuilderTasks
            .filter { $0.category == .building || $0.category == .townHall }
            .map(\.endDay)
            .min() ?? 0
        let researchEnd = research.first?.endDay ?? buildingEnd
        let syncScore = max(0, min(100, Int((100 - abs(buildingEnd - researchEnd) * 6).rounded())))

        let earlyTownHallRisk: Int
        if let townHall = plannedBuilderTasks.first(where: { $0.category == .townHall }) {
            let readinessBase: Int
            switch input.nextTownHallReadiness {
            case .ready: readinessBase = 8
            case .nearlyReady: readinessBase = 28
            case .notReady: readinessBase = 72
            }
            earlyTownHallRisk = townHall.startDay < 7 ? min(100, readinessBase + 20) : readinessBase
        } else {
            earlyTownHallRisk = 0
        }

        let dataBackedCount = allTasks.filter { task in
            guard let key = task.dataKey else { return false }
            return catalog.entry(for: key) != nil
        }.count
        let dataCoveragePercent = allTasks.isEmpty ? 0 : Int((Double(dataBackedCount) / Double(allTasks.count) * 100).rounded())
        let overallScore = max(0, min(100, Int((
            Double(warFriendlyScore) * 0.42
                + Double(100 - resourcePressure) * 0.28
                + Double(syncScore) * 0.30
        ).rounded())))

        return PlanMetrics(
            overallScore: overallScore,
            warFriendlyScore: warFriendlyScore,
            resourcePressure: resourcePressure,
            syncScore: syncScore,
            earlyTownHallRisk: earlyTownHallRisk,
            activeBuilders: builders.filter { !$0.tasks.isEmpty }.count,
            plannedTaskCount: allTasks.count,
            resourceBlockedCount: resourceBlockedCount,
            dataCoveragePercent: dataCoveragePercent
        )
    }

    private func peakOverlap(in tasks: [PlannedTask]) -> Int {
        let points = tasks.flatMap { [$0.startDay, $0.endDay] }.sorted()
        return points.map { point in
            tasks.filter { $0.startDay <= point && $0.endDay > point }.count
        }.max() ?? 0
    }

    private func makeInsights(
        input: PlannerInput,
        metrics: PlanMetrics,
        research: [PlannedTask],
        catalog: GameDataCatalog
    ) -> [PlannerInsight] {
        var insights: [PlannerInsight] = []

        switch input.warMode {
        case .league where input.reserveHeroesDuringLeague:
            insights.append(PlannerInsight(
                title: "联赛窗口已保护",
                message: "英雄升级从保护窗口结束后开始，先保证联赛期间有完整出战阵容。",
                tone: .positive
            ))
        case .warReady:
            insights.append(PlannerInsight(
                title: "部落战体验优先",
                message: "英雄会参考当前出战保护窗口轮换；如果近期有关键战，可以把保护结束日继续后移。",
                tone: .information
            ))
        case .relaxed, .league:
            insights.append(PlannerInsight(
                title: "效率优先模式",
                message: "当前没有为所有英雄安排完整保护窗口，预计成长更快但会牺牲部分出战时间。",
                tone: .neutral
            ))
        }

        switch input.nextTownHallReadiness {
        case .ready:
            insights.append(PlannerInsight(
                title: "大本营窗口可用",
                message: "规划器允许大本营进入核心建筑队列，但仍会让实验室与兵营保持衔接。",
                tone: .positive
            ))
        case .nearlyReady:
            insights.append(PlannerInsight(
                title: "大本营稍后启动",
                message: "先用约 7 天完成准备，避免下一大本升级过早造成科技和英雄脱节。",
                tone: .warning
            ))
        case .notReady:
            insights.append(PlannerInsight(
                title: "暂缓下一大本",
                message: "当前把大本营推迟到约第 15 天；请先补齐关键进攻能力。",
                tone: .warning
            ))
        }

        if input.magicItemsAvailable {
            insights.append(PlannerInsight(
                title: "魔法物品使用点",
                message: "优先考虑最长的英雄升级，且避开英雄出战保护窗口；科技药水适合放在连续科技队列开始时。",
                tone: .information
            ))
        } else {
            insights.append(PlannerInsight(
                title: "魔法物品未计入",
                message: "打开魔法物品库存后，规划器可以把英雄长周期和连续科技作为候选使用点。",
                tone: .neutral
            ))
        }

        if input.checkInFrequency == .once {
            insights.append(PlannerInsight(
                title: "按低频上线安排",
                message: "城墙、陷阱和资源建筑会被拆成较少的操作批次，减少每天必须打开游戏的次数。",
                tone: .information
            ))
        }

        if metrics.resourceBlockedCount > 0 {
            insights.append(PlannerInsight(
                title: "有任务被库存卡住",
                message: "至少一个任务的当前库存不足；规划器已按日收入把它后移，而不是假设资源凭空出现。",
                tone: .warning
            ))
        } else if metrics.resourcePressure <= 20 {
            insights.append(PlannerInsight(
                title: "资源峰值可控",
                message: "当前库存、日收入和任务成本没有形成明显堵点，适合日常收菜节奏。",
                tone: .positive
            ))
        } else {
            insights.append(PlannerInsight(
                title: "资源压力偏高",
                message: "可以增加上线频率、关闭部分错峰，或把一个高资源任务换成城墙/陷阱批次。",
                tone: .warning
            ))
        }

        if catalog.source == .demo || catalog.source == .officialPending {
            insights.append(PlannerInsight(
                title: "数据层仍是演示/待确认",
                message: catalog.status.versionLabel + "；当前工期仍以你填写的剩余时间为准，成本只是可审计的占位元数据。",
                tone: .warning
            ))
        } else {
            insights.append(PlannerInsight(
                title: "数据层版本已绑定",
                message: catalog.status.versionLabel + " · " + catalog.source.title + " · 覆盖度 " + String(metrics.dataCoveragePercent) + "%",
                tone: .positive
            ))
        }

        if research.isEmpty {
            insights.append(PlannerInsight(
                title: "科技队列为空",
                message: "建筑与科技无法同步评估；请至少添加一个科技目标。",
                tone: .warning
            ))
        }

        return insights
    }
}
