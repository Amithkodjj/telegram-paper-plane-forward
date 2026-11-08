import UIKit
import Display
import TelegramCore
import SwiftSignalKit
import ChatMessageItemView
import PaperPlaneForward

extension ChatControllerImpl {
    enum PaperPlaneToastPosition {
        case top
        case bottom
        case inChat
    }

    func preparePaperPlaneForward(messageIds: Set<EngineMessage.Id>) -> ((PaperPlaneToastPosition, @escaping () -> Void, (() -> Void)?) -> Void)? {
        guard !UIAccessibility.isReduceMotionEnabled else {
            return nil
        }
        if case let .peer(peerId) = self.chatLocation, peerId.namespace == Namespaces.Peer.SecretChat {
            return nil
        }

        var items: [PaperPlaneItem] = []
        let hostView: UIView = self.view
        self.chatDisplayNode.historyNode.forEachItemNode { itemNode in
            guard let itemNode = itemNode as? ChatMessageItemView, let item = itemNode.item else {
                return
            }
            guard item.content.contains(where: { messageIds.contains($0.0.id) }) else {
                return
            }
            guard let (image, subFrame) = itemNode.makeContentSnapshot(), let cgImage = image.cgImage else {
                return
            }
            let frame = itemNode.view.convert(subFrame, to: hostView)
            guard frame.intersects(hostView.bounds) else {
                return
            }
            items.append(PaperPlaneItem(frame: frame, image: cgImage))
        }
        guard !items.isEmpty else {
            return nil
        }
        // The history list is rotated by π: order by position on screen, top to bottom.
        items.sort { $0.frame.minY < $1.frame.minY }

        guard let animator = PaperPlaneForwardAnimator() else {
            return nil
        }
        animator.prewarm()
        let theme: PaperPlaneTheme = self.presentationData.theme.overallDarkAppearance ? .night : .day

        return { [weak self] position, presentToast, onLanded in
            // Wait for the peer picker to slide away and the chat to be back on screen.
            Queue.mainQueue().after(0.42) {
                guard let self, let window = self.view.window else {
                    presentToast()
                    onLanded?()
                    return
                }
                let backgroundView = self.chatDisplayNode.backgroundNode.view
                let wallpaper = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    let frame = backgroundView.convert(backgroundView.bounds, to: window)
                    backgroundView.drawHierarchy(in: frame, afterScreenUpdates: false)
                }.cgImage

                animator.view.frame = window.bounds
                window.addSubview(animator.view)
                // UndoOverlayController draws its icon 10 pt inside the panel's leading edge; the panel
                // sits above the input panel (bottom) or below the navigation bar (top).
                let safe = window.safeAreaInsets
                let target: CGPoint
                switch position {
                case .bottom:
                    target = CGPoint(x: safe.left + 10.0 + 9.0 + 16.0, y: window.bounds.height - safe.bottom - 52.0 - 8.0 - 25.0)
                case .top:
                    target = CGPoint(x: safe.left + 10.0 + 9.0 + 16.0, y: safe.top + 8.0 + 25.0)
                case .inChat:
                    let visibleArea = self.chatDisplayNode.frameForVisibleArea()
                    target = CGPoint(x: window.bounds.width - safe.right - 72.0, y: visibleArea.maxY - 30.0)
                }
                animator.onLaunch = {
                    presentToast()
                }
                animator.onArrive = {
                    onLanded?()
                }
                animator.onCompletion = { [weak animatorView = animator.view] in
                    animatorView?.removeFromSuperview()
                }
                animator.retainedUntilCompletion = animator
                animator.start(items: items, wallpaper: wallpaper, target: target, theme: theme)
            }
        }
    }
}
