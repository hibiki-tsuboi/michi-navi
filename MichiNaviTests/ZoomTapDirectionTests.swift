import Foundation
import Testing

@testable import MichiNavi

/// 拡大・縮小ボタンを連打したときの向き。
///
/// CarPlay ホストは 1 本指ダブルタップの認識器を `CPSMapTemplateViewController` の
/// root view に付けていて、`mapButtons` はその view の子。**同じ場所を続けて叩くと
/// ダブルタップが成立し、ボタンの 2 回目の押下は `cancelsTouchesInView` で取り消される。**
/// そのため素直に `velocity` の符号へ従うと、縮小ボタンの 2 回目だけが拡大になる。
///
/// 症状が出るのは実車か CarPlay Simulator で連打したときだけなので、条件を外したら
/// 落ちるようにしておく。
@MainActor
struct ZoomTapDirectionTests {
    /// ダブルタップの velocity は +1、2 本指タップは -1（26.6 の
    /// `_handleOneFingerDoubleTapGesture:` / `_handleTwoFingerTapGesture:` で確認）。
    private let doubleTap: CGFloat = 1
    private let twoFingerTap: CGFloat = -1

    private let now = Date(timeIntervalSinceReferenceDate: 1_000)

    @Test("縮小ボタンの直後のダブルタップは縮小のまま")
    func takesOverAfterZoomOutButton() {
        let direction = CarPlayCoordinator.zoomDirection(
            velocity: doubleTap,
            lastStep: (isZoomingIn: false, at: now.addingTimeInterval(-0.2)),
            now: now)
        #expect(direction == false)
    }

    @Test("拡大ボタンの直後のダブルタップは拡大のまま")
    func keepsDirectionAfterZoomInButton() {
        let direction = CarPlayCoordinator.zoomDirection(
            velocity: doubleTap,
            lastStep: (isZoomingIn: true, at: now.addingTimeInterval(-0.2)),
            now: now)
        #expect(direction == true)
    }

    /// **猶予を過ぎたら本物のダブルタップとして扱う。** ここを外すと、縮小ボタンを
    /// 押したあといつまでもダブルタップが縮小になる。
    @Test("猶予を過ぎたダブルタップは拡大")
    func treatsLateTapAsRealDoubleTap() {
        let direction = CarPlayCoordinator.zoomDirection(
            velocity: doubleTap,
            lastStep: (isZoomingIn: false, at: now.addingTimeInterval(-2)),
            now: now)
        #expect(direction == true)
    }

    /// **2 本指のタップはボタンの押下になりえない**（認識器の
    /// `numberOfTouchesRequired` が 2）。直前が拡大でも縮小のまま通す。
    @Test("2 本指タップは直前のボタンに引きずられない")
    func twoFingerTapIsNeverTakenOver() {
        let direction = CarPlayCoordinator.zoomDirection(
            velocity: twoFingerTap,
            lastStep: (isZoomingIn: true, at: now.addingTimeInterval(-0.2)),
            now: now)
        #expect(direction == false)
    }

    @Test("直前のボタンが無ければ符号どおり")
    func fallsBackToVelocitySign() {
        #expect(CarPlayCoordinator.zoomDirection(velocity: doubleTap, lastStep: nil, now: now) == true)
        #expect(CarPlayCoordinator.zoomDirection(velocity: twoFingerTap, lastStep: nil, now: now) == false)
    }
}
