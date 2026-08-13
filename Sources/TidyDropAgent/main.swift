import Foundation
import TidyDropCore

let rawArguments = Array(CommandLine.arguments.dropFirst())
let configurationURL: URL
if rawArguments.isEmpty {
    configurationURL = ConfigurationIO.defaultConfigPath()
} else if rawArguments.count == 2, rawArguments[0] == "--config" {
    configurationURL = URL(
        fileURLWithPath: NSString(string: rawArguments[1]).expandingTildeInPath
    )
} else {
    fputs("usage: tidydrop-agent [--config PATH]\n", stderr)
    exit(2)
}

exit(ScheduledExecution.run(configurationURL: configurationURL))
