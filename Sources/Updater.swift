import AppKit
import Sparkle

/// 앱이 스스로 업데이트를 받아 교체한다.
///
/// 예전에는 새 버전이 있으면 알림창을 띄우고 브라우저로 DMG 주소를 열어 줬다. 그러면 사용자가
/// 앱을 끄고, DMG 를 열고, Applications 로 끌어넣고, 교체 확인까지 눌러야 했다. 네 단계다.
/// Sparkle 은 내려받기·교체·재시작을 다 한다 — 사용자는 "설치"만 누른다.
///
/// 설정은 Info.plist 에 있다.
///   SUFeedURL               appcast.xml 주소 (brefly-pages 에 올린다)
///   SUPublicEDKey           업데이트 서명 검증용 공개키
///   SUEnableAutomaticChecks 자동 확인 켬
///   SUScheduledCheckInterval 86400초(하루)
///
/// ⚠️ 서명 개인키를 잃으면 기존 사용자에게 업데이트를 영영 보낼 수 없다.
///    로그인 키체인의 "Private key for signing Sparkle updates" 항목이다.
enum Updater {

    /// Sparkle 이 앱이 사는 동안 살아 있어야 해서 전역으로 붙잡아 둔다.
    private static var controller: SPUStandardUpdaterController?
    /// 대리자는 Sparkle 이 약하게 붙잡으므로 우리가 들고 있어야 한다.
    private static let postponer = UpdatePostponer()

    /// 녹음·회의록처럼 끊기면 안 되는 일이 도는지 알려 준다.
    static func reportBusy(_ isBusy: @escaping () -> Bool) { postponer.isBusy = isBusy }

    /// 앱 시작 때 한 번. 이후 확인 주기는 Sparkle 이 알아서 관리한다.
    static func start() {
        guard controller == nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: postponer,
                                                  userDriverDelegate: nil)
        Log.write("Sparkle 시작 — 자동 확인 \(Prefs.autoCheckUpdates ? "켬" : "끔")")
        controller?.updater.automaticallyChecksForUpdates = Prefs.autoCheckUpdates
    }

    /// 설정 > 업데이트 의 "확인" 버튼. 최신이어도 결과 창을 띄운다.
    static func checkManually() {
        guard let controller else {
            Log.write("Sparkle 이 아직 시작되지 않아 수동 확인을 건너뜀")
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    /// 설정에서 자동 확인을 켜고 끌 때 Sparkle 에도 알려 준다.
    static func setAutomaticChecks(_ on: Bool) {
        controller?.updater.automaticallyChecksForUpdates = on
    }

    /// 마지막으로 확인한 시각. 설정 화면에 보여 줄 수 있다.
    static var lastCheckDate: Date? { controller?.updater.lastUpdateCheckDate }
}


/// 업데이트 설치를 잠깐 미룬다.
///
/// 설치하면 앱이 잠깐 꺼졌다 켜진다. 녹음 중이거나 회의록을 만드는 중에 그러면 하던 일이
/// 통째로 날아간다. 회의록은 1~2분짜리라 특히 아깝다. 끝날 때까지 기다렸다가 설치한다(시안 8번).
final class UpdatePostponer: NSObject, SPUUpdaterDelegate {
    /// 지금 오래 걸리는 일이 도는지. 앱 쪽에서 채운다.
    var isBusy: () -> Bool = { false }
    private var pendingInstall: (() -> Void)?
    private var waitTimer: Timer?

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard isBusy() else { return false }
        Log.write("업데이트 설치를 미룬다 — 하던 일이 끝나면 설치한다")
        pendingInstall = installHandler
        waitTimer?.invalidate()
        waitTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] timer in
            guard let self, !self.isBusy() else { return }
            timer.invalidate()
            self.waitTimer = nil
            let install = self.pendingInstall
            self.pendingInstall = nil
            Log.write("하던 일이 끝나 업데이트를 설치한다")
            install?()
        }
        return true
    }
}
