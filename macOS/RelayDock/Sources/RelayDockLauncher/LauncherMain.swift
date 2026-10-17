import Foundation

@main
struct LauncherMain {
    static func main() {
        Launcher.run(
            commandLineArguments: CommandLine.arguments,
            environment: ProcessInfo.processInfo.environment
        )
    }
}
