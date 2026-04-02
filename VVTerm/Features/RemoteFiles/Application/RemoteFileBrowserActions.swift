import Foundation

extension RemoteFileBrowserStore {
    func requestUploadPicker(for serverId: UUID, destinationPath: String) {
        setPendingToolbarCommand(
            ToolbarCommand(
                serverId: serverId,
                action: .upload(destinationPath: RemoteFilePath.normalize(destinationPath))
            )
        )
    }

    func requestCreateFolder(for serverId: UUID, destinationPath: String) {
        setPendingToolbarCommand(
            ToolbarCommand(
                serverId: serverId,
                action: .createFolder(destinationPath: RemoteFilePath.normalize(destinationPath))
            )
        )
    }

    func consumeToolbarCommand(_ command: ToolbarCommand) {
        guard pendingToolbarCommand?.id == command.id else { return }
        setPendingToolbarCommand(nil)
    }
}
