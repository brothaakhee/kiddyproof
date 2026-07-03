import Foundation
import Carbon.HIToolbox

// Secure Event Input is the one irreducible hole. When any app has it on (a focused
// password field, Terminal with "Secure Keyboard Entry", 1Password, sudo/FileVault
// prompts), keystrokes are delivered straight to that app and are invisible AND
// unblockable by our tap. There is no userspace fix, so we must:
//   1. Refuse to arm kid mode while it is on.
//   2. Poll while armed and bail loudly if it turns on mid-session.
// The mouse-corner exit still works in that case, which is why exit is mouse-first.
enum SecureInputGuard {
    static func isActive() -> Bool {
        return IsSecureEventInputEnabled()
    }
}
