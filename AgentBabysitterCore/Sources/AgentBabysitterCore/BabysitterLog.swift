import os

/// Central loggers — view with `log stream --predicate 'subsystem ==
/// "app.agentbabysitter"'` or Console.app. Session ids and file paths are
/// logged public (they're the user's own data on their own machine);
/// transcript content is never logged.
public enum BabysitterLog {
    public static let store = Logger(subsystem: "app.agentbabysitter", category: "store")
    public static let watcher = Logger(subsystem: "app.agentbabysitter", category: "watcher")
    public static let process = Logger(subsystem: "app.agentbabysitter", category: "process")
    public static let hooks = Logger(subsystem: "app.agentbabysitter", category: "hooks")
}
