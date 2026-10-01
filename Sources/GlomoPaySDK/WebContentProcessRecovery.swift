enum WebContentProcessRecovery {
    enum Action: Equatable {
        case closeFlow
        case reloadMain
        case reportMainFailure
    }

    static func action(isFlow: Bool, didRetryMain: Bool, hasCurrentURL: Bool) -> Action {
        if isFlow { return .closeFlow }
        if !didRetryMain && hasCurrentURL { return .reloadMain }
        return .reportMainFailure
    }
}
