import Foundation

nonisolated enum ZellijSocketNamespace: Sendable {
    case user
    case managed

    init(ownership: RemoteSessionOwnership) {
        self = ownership == .managed ? .managed : .user
    }

    var setupScript: String {
        switch self {
        case .user:
            return ""
        case .managed:
            return """
            vvtermZellijUID="$(id -u)"
            case "$vvtermZellijUID" in ''|*[!0-9]*) exit 1 ;; esac
            ZELLIJ_SOCKET_DIR="/tmp/vvterm-zellij-$vvtermZellijUID"
            if [ ! -d "$ZELLIJ_SOCKET_DIR" ]; then
              (umask 077; mkdir "$ZELLIJ_SOCKET_DIR") 2>/dev/null || true
            fi
            [ -d "$ZELLIJ_SOCKET_DIR" ] && [ ! -L "$ZELLIJ_SOCKET_DIR" ] || exit 1
            vvtermZellijOwner="$(stat -f '%u' "$ZELLIJ_SOCKET_DIR" 2>/dev/null || true)"
            case "$vvtermZellijOwner" in
              ''|*[!0-9]*) vvtermZellijOwner="$(stat -c '%u' "$ZELLIJ_SOCKET_DIR" 2>/dev/null || true)" ;;
            esac
            [ "$vvtermZellijOwner" = "$vvtermZellijUID" ] || exit 1
            chmod 700 "$ZELLIJ_SOCKET_DIR" || exit 1
            export ZELLIJ_SOCKET_DIR
            """
        }
    }
}
