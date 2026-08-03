import Combine
import Foundation
import COCHelperCore

@MainActor
final class AppModel: ObservableObject {
    @Published var input: PlannerInput
    @Published private(set) var plan: RoadmapPlan

    private let planner = RoadmapPlanner()
    private let defaults = UserDefaults.standard
    private let storageKey = "coc-helper.planner-input.v1"

    init() {
        let initialInput: PlannerInput
        if let saved = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(PlannerInput.self, from: saved) {
            initialInput = decoded
        } else {
            initialInput = .demo
        }
        input = initialInput
        plan = RoadmapPlanner().makePlan(for: initialInput)
    }

    func rebuild() {
        plan = planner.makePlan(for: input)
        persist()
    }

    func resetToDemo() {
        input = .demo
        rebuild()
    }

    func addTask(_ task: UpgradeTask) {
        input.tasks.append(task)
        rebuild()
    }

    func removeTask(id: UUID) {
        input.tasks.removeAll { $0.id == id }
        rebuild()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(input) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
