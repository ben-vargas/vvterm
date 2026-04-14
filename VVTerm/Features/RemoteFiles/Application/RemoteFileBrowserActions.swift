import Combine
import Foundation

extension RemoteFileBrowserStore {
    func requestUploadPicker(for tab: RemoteFileTab, destinationPath: String) {
        setPendingToolbarCommand(
            ToolbarCommand(
                serverId: tab.serverId,
                tabId: tab.id,
                action: .upload(destinationPath: RemoteFilePath.normalize(destinationPath))
            )
        )
    }

    func requestCreateFolder(for tab: RemoteFileTab, destinationPath: String) {
        setPendingToolbarCommand(
            ToolbarCommand(
                serverId: tab.serverId,
                tabId: tab.id,
                action: .createFolder(destinationPath: RemoteFilePath.normalize(destinationPath))
            )
        )
    }

    func consumeToolbarCommand(_ command: ToolbarCommand) {
        guard pendingToolbarCommand?.id == command.id else { return }
        setPendingToolbarCommand(nil)
    }
}
