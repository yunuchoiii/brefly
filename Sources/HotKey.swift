import Foundation
import Carbon.HIToolbox
import AppKit

/// Carbon 전역 핫키. 접근성 권한 없이도 등록되며 어느 앱이 앞에 있든 동작한다.
enum HotKey {

    /// 어느 단축키인지. Carbon 의 `EventHotKeyID.id` 로 쓰므로 값이 겹치면 안 된다.
    enum Slot: UInt32, CaseIterable {
        case dictation = 1   // 받아쓰기
        case inPerson  = 2   // 대면 회의 녹음
        case videoCall = 3   // 화상 회의 녹음
        case highlight = 4   // 녹음 중 중요 구간 표시
    }

    private static var handlerRef: EventHandlerRef?
    /// ⚠️ 슬롯마다 따로 들고 있어야 한다. 전에는 하나만 두고 등록할 때마다 앞의 것을
    ///    내려서, 단축키를 둘 이상 쓸 수가 없었다.
    private static var refs: [Slot: EventHotKeyRef] = [:]
    private static var actions: [Slot: () -> Void] = [:]

    /// 'SOKG' 시그니처
    private static let signature = OSType(0x534F4B47)

    @discardableResult
    static func register(_ slot: Slot, keyCode: UInt32, modifiers: UInt32,
                         action: @escaping () -> Void) -> Bool {
        unregister(slot)
        actions[slot] = action
        guard installHandlerIfNeeded() else { return false }

        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: signature, id: slot.rawValue)
        let status = RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { actions[slot] = nil; return false }
        refs[slot] = ref
        return true
    }

    /// 핸들러는 하나면 된다. 눌린 키의 `id` 로 어느 슬롯인지 가린다.
    private static func installHandlerIfNeeded() -> Bool {
        guard handlerRef == nil else { return true }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                var id = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                  EventParamType(typeEventHotKeyID), nil,
                                  MemoryLayout<EventHotKeyID>.size, nil, &id)
                if let slot = Slot(rawValue: id.id) {
                    DispatchQueue.main.async { HotKey.actions[slot]?() }
                }
                return noErr
            },
            1, &spec, nil, &handlerRef)
        return status == noErr
    }

    static func unregister(_ slot: Slot) {
        if let ref = refs[slot] { UnregisterEventHotKey(ref) }
        refs[slot] = nil
        actions[slot] = nil
    }

    static func unregisterAll() {
        for slot in Slot.allCases { unregister(slot) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        handlerRef = nil
    }
}

/// 키 코드 + Carbon 수정자 조합. 프리셋이든 직접 녹음한 것이든 이 하나로 다룬다.
struct HotKeyCombo: Equatable {
    let keyCode: UInt32
    let modifiers: UInt32

    /// keyCode 가 이 값이면 "수정자 키만 눌렀다 떼는" 단축키 (예: fn⌃). Carbon 이 아니라 이벤트 모니터로 잡는다.
    static let modifierOnlyKeyCode: UInt32 = 0xFFFF
    /// Carbon 에는 fn 이 없어서 앱에서만 쓰는 비트.
    static let fnFlag: UInt32 = 1 << 20

    var isModifierOnly: Bool { keyCode == Self.modifierOnlyKeyCode }

    /// "⌃⌥Space", "fn⌃" 처럼 표시
    var title: String { isModifierOnly ? modifierSymbols : modifierSymbols + Self.keyName(keyCode) }

    var modifierSymbols: String {
        var t = ""
        if modifiers & Self.fnFlag != 0            { t += "fn" }
        if modifiers & UInt32(controlKey) != 0 { t += "⌃" }
        if modifiers & UInt32(optionKey)  != 0 { t += "⌥" }
        if modifiers & UInt32(shiftKey)   != 0 { t += "⇧" }
        if modifiers & UInt32(cmdKey)     != 0 { t += "⌘" }
        return t
    }

    /// NSEvent 의 수정자 플래그를 Carbon 값으로. fn 은 뺀다 (화살표·F키 이벤트에도 .function 이 붙는다).
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.option)  { m |= UInt32(optionKey) }
        if flags.contains(.shift)   { m |= UInt32(shiftKey) }
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        return m
    }

    /// 수정자 전용 단축키용: fn 까지 포함.
    static func modifierBits(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var m = carbonModifiers(from: flags)
        if flags.contains(.function) { m |= fnFlag }
        return m
    }

    static func keyName(_ code: UInt32) -> String {
        if let n = keyNames[Int(code)] { return n }
        return "키\(code)"
    }

    private static let keyNames: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "Home", kVK_End: "End", kVK_PageUp: "PgUp", kVK_PageDown: "PgDn",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E", kVK_ANSI_F: "F",
        kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
        kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R",
        kVK_ANSI_S: "S", kVK_ANSI_T: "T", kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
        kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
        kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
        kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".",
        kVK_ANSI_Slash: "/", kVK_ANSI_Backslash: "\\", kVK_ANSI_Grave: "`"
    ]
}

/// 수정자 키만 눌렀다 떼면 발동하는 단축키. 다른 키가 끼면 취소된다 (⌃C 같은 입력에 안 걸린다).
/// 전역 이벤트 모니터라 손쉬운 사용 권한이 있어야 다른 앱 위에서 동작한다.
enum ModifierHotKey {
    private static var monitors: [Any] = []
    /// ⚠️ 슬롯마다 따로 들고 있어야 여러 개를 쓸 수 있다. `armed` 도 슬롯별이다 —
    ///    하나로 두면 fn⌃ 를 누르는 동안 fn⌥ 의 상태까지 같이 풀린다.
    private static var targets: [HotKey.Slot: UInt32] = [:]
    private static var actions: [HotKey.Slot: () -> Void] = [:]
    private static var armed: Set<HotKey.Slot> = []

    static var isAvailable: Bool { AXIsProcessTrusted() }

    @discardableResult
    static func register(_ slot: HotKey.Slot, _ combo: HotKeyCombo,
                         action: @escaping () -> Void) -> Bool {
        guard combo.isModifierOnly, combo.modifiers != 0, isAvailable else { return false }
        targets[slot] = combo.modifiers
        actions[slot] = action
        installMonitorsIfNeeded()
        return !monitors.isEmpty
    }

    /// 감시기는 하나면 된다. 들어온 수정자 조합을 슬롯마다 견준다.
    private static func installMonitorsIfNeeded() {
        guard monitors.isEmpty else { return }
        let handle: (NSEvent) -> Void = { event in
            guard event.type == .flagsChanged else { armed.removeAll(); return }
            let now = HotKeyCombo.modifierBits(from: event.modifierFlags)
            // ⚠️ 더 많은 키를 쓴 단축키를 먼저 본다. fn⌃ 와 fn⌃⌥ 가 함께 있을 때
            //    짧은 쪽이 먼저 걸리면 긴 쪽은 영영 못 누른다.
            for (slot, target) in targets.sorted(by: { $0.value.nonzeroBitCount > $1.value.nonzeroBitCount }) {
                if now == target {
                    armed.insert(slot)
                } else if armed.contains(slot), now & target != target {
                    armed.remove(slot)
                    if let action = actions[slot] { DispatchQueue.main.async(execute: action) }
                } else {
                    armed.remove(slot)
                }
            }
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: handle) {
            monitors.append(g)
        }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: { handle($0); return $0 }) {
            monitors.append(l)
        }
    }

    static func unregister(_ slot: HotKey.Slot) {
        targets[slot] = nil
        actions[slot] = nil
        armed.remove(slot)
        if targets.isEmpty { unregisterAll() }
    }

    static func unregisterAll() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
        targets = [:]
        actions = [:]
        armed = []
    }
}

/// 단축키 프리셋. 메뉴에서 고를 수 있게 해 둔다.
struct HotKeyPreset {
    let title: String
    let keyCode: UInt32
    let modifiers: UInt32

    static let all: [HotKeyPreset] = [
        HotKeyPreset(title: "⌃⌥Space", keyCode: UInt32(kVK_Space),
                     modifiers: UInt32(controlKey | optionKey)),
        HotKeyPreset(title: "⌥Space", keyCode: UInt32(kVK_Space),
                     modifiers: UInt32(optionKey)),
        HotKeyPreset(title: "⌃⌥D", keyCode: UInt32(kVK_ANSI_D),
                     modifiers: UInt32(controlKey | optionKey)),
        HotKeyPreset(title: "⌘⇧Space", keyCode: UInt32(kVK_Space),
                     modifiers: UInt32(cmdKey | shiftKey))
    ]

    static func preset(at index: Int) -> HotKeyPreset {
        all.indices.contains(index) ? all[index] : all[0]
    }

    var combo: HotKeyCombo { HotKeyCombo(keyCode: keyCode, modifiers: modifiers) }
}
