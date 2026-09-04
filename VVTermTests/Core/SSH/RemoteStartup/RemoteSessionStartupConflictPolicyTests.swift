import Testing
@testable import VVTerm

struct RemoteSessionStartupConflictPolicyTests {
    @Test
    func detectsDirectSessionManagerCommands() {
        let commands = [
            "tmux attach",
            "cd ~/project && exec /usr/bin/zmx attach",
            "nohup env TERM=xterm-256color command zellij attach main",
            "C:\\tools\\psmux.exe attach",
            "pmux attach",
            "herdr attach"
        ]

        for command in commands {
            #expect(RemoteSessionStartupConflictPolicy.invokesSessionManager(in: command))
        }
    }

    @Test
    func permitsCommandsThatOnlyMentionSessionManagers() {
        let commands = [
            "printf 'tmux attach'",
            "echo zmx",
            "export SESSION_TOOL=zellij",
            "cd ~/tmux-project && exec $SHELL -l"
        ]

        for command in commands {
            #expect(!RemoteSessionStartupConflictPolicy.invokesSessionManager(in: command))
        }
    }
}
