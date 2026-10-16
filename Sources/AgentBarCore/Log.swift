import os

/// Central loggers — subsystem io.github.kankunnawat.agentbar. View with:
/// log stream --predicate 'subsystem == "io.github.kankunnawat.agentbar"'
public enum Log {
    public static let fetch = Logger(subsystem: "io.github.kankunnawat.agentbar", category: "fetch")
    public static let keychain = Logger(subsystem: "io.github.kankunnawat.agentbar", category: "keychain")
    public static let refresh = Logger(subsystem: "io.github.kankunnawat.agentbar", category: "refresh")
    public static let config = Logger(subsystem: "io.github.kankunnawat.agentbar", category: "config")
    public static let cost = Logger(subsystem: "io.github.kankunnawat.agentbar", category: "cost")
    public static let history = Logger(subsystem: "io.github.kankunnawat.agentbar", category: "history")
}
