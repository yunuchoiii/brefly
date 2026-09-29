import AppKit
import SwiftUI

// MARK: - 팔레트 (시안 "Voice Summary App.dc.html" 에서 그대로 가져옴)

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
                  green: CGFloat((hex >> 8) & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255,
                  alpha: 1)
    }
}

enum Theme {
    // 브랜드
    static let ink        = NSColor(hex: 0x16181d)   // 잉크 블랙
    static let inkDeep    = NSColor(hex: 0x101216)
    static let coral      = NSColor(hex: 0xe0604a)   // 레코딩 코랄
    static let amber      = NSColor(hex: 0xe0a24a)   // 정리 중 (코랄과 같은 계열)
    static let done       = NSColor(hex: 0x3f9c5f)   // 끝남 (밝은·어두운 메뉴바 양쪽에서 보이는 중간 밝기 초록)
    static let coralDeep  = NSColor(hex: 0xc2452f)
    static let coralLight = NSColor(hex: 0xff6b52)

    // 라이트 화면
    static let paper      = NSColor.white
    static let paperSoft  = NSColor(hex: 0xfbfbfc)
    static let fill       = NSColor(hex: 0xf2f3f5)
    static let line       = NSColor(hex: 0xeceef1)
    static let lineStrong = NSColor(hex: 0xdcdfe4)
    static let text2      = NSColor(hex: 0x6f7580)
    static let text3      = NSColor(hex: 0x8b909a)
    static let text4      = NSColor(hex: 0xa6acb8)
    /// 선택 안 된 라디오 테두리. 기존 선 색(0xdcdfe4)은 흰 바탕에서 1.3:1 이라 거의 안 보인다.
    static let radioOff   = NSColor(hex: 0x8b909a)

    // 완료 토스트
    static let green       = NSColor(hex: 0x3f9e6e)
    static let greenText   = NSColor(hex: 0x256b48)
    static let greenSub    = NSColor(hex: 0x5e8e75)
    static let greenBG     = NSColor(hex: 0xe9f4ee)
    static let greenBorder = NSColor(hex: 0xcfe6d9)

    // 다크(녹음 중) 화면
    static let darkPanel = NSColor(hex: 0x1d2026)
    static let darkCard  = NSColor(hex: 0x2a2d35)
    static let darkLine  = NSColor(hex: 0x3a3e47)
    static let darkMuted = NSColor(hex: 0x565b66)
    static let darkText  = NSColor(hex: 0xcdd1d8)
    static let darkSub   = NSColor(hex: 0x9ba0a9)
}

extension Theme {
    /// 라이트/다크 자동 전환 색. 뷰의 appearance 에 따라 그릴 때 결정된다.
    static func dyn(_ light: NSColor, _ dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    // 다크 모드 짝 (시안은 라이트만 있어서 녹음 화면 팔레트를 바탕으로 정했다)
    static let darkPaper     = NSColor(hex: 0x1d2026)
    static let darkPaperSoft = NSColor(hex: 0x181b20)
    static let darkFill      = NSColor(hex: 0x2a2d35)
    static let darkHair      = NSColor(hex: 0x2e323a)
    static let darkTextMain  = NSColor(hex: 0xf2f3f5)
    static let darkGreenBG     = NSColor(hex: 0x1f2f27)
    static let darkGreenBorder = NSColor(hex: 0x2c4a3a)
    static let darkGreenText   = NSColor(hex: 0x8fd3b0)
    static let darkGreenSub    = NSColor(hex: 0x6fa88a)

    /// 팝오버 배경 뷰처럼 CGColor 가 필요한 곳 — 현재 모드에 맞춰 고정 색을 고른다.
    static func paperColor(dark: Bool) -> NSColor { dark ? darkPaper : paper }
}

extension Color {
    // 텍스트·면 — 모드에 따라 바뀜
    static let ink        = Color(nsColor: Theme.dyn(Theme.ink, Theme.darkTextMain))      // 본문 글자
    static let primaryFill = Color(nsColor: Theme.dyn(Theme.ink, Theme.darkTextMain))     // 검은 버튼·선택 핀
    static let onPrimary  = Color(nsColor: Theme.dyn(.white, Theme.ink))                  // 그 위 글자
    static let paper      = Color(nsColor: Theme.dyn(Theme.paper, Theme.darkPaper))
    static let paperSoft  = Color(nsColor: Theme.dyn(Theme.paperSoft, Theme.darkPaperSoft))
    static let fill       = Color(nsColor: Theme.dyn(Theme.fill, Theme.darkFill))
    static let line       = Color(nsColor: Theme.dyn(Theme.line, Theme.darkHair))
    static let lineStrong = Color(nsColor: Theme.dyn(Theme.lineStrong, Theme.darkLine))
    static let radioOff   = Color(nsColor: Theme.dyn(Theme.radioOff, Theme.darkSub))
    /// 회의록 시작 줄 셋. 시안이 색을 단계로 낮춰 "누르면 바로 시작 / 창을 여는 동작"을 가른다.
    /// 어두운 모드에서는 뒤집는다 — 어두운 배경 위에 어두운 칸을 얹으면 안 보인다.
    static let meetingRow1 = Color(nsColor: Theme.dyn(NSColor(hex: 0x16181d), NSColor(hex: 0xf2f3f5)))
    static let meetingRow2 = Color(nsColor: Theme.dyn(NSColor(hex: 0x2a2d35), NSColor(hex: 0xdcdfe4)))
    static let meetingRow3 = Color(nsColor: Theme.dyn(NSColor(hex: 0x3a3e47), NSColor(hex: 0xc9cdd4)))
    static let onMeetingRow = Color(nsColor: Theme.dyn(NSColor.white, NSColor(hex: 0x16181d)))
    static let onMeetingRowSub = Color(nsColor: Theme.dyn(NSColor(hex: 0xcdd1d8), NSColor(hex: 0x4b515c)))
    static let text2      = Color(nsColor: Theme.dyn(Theme.text2, Theme.darkText))
    static let text3      = Color(nsColor: Theme.dyn(Theme.text3, Theme.darkSub))
    static let text4      = Color(nsColor: Theme.dyn(Theme.text4, Theme.darkMuted))
    static let greenText  = Color(nsColor: Theme.dyn(Theme.greenText, Theme.darkGreenText))
    static let greenSub   = Color(nsColor: Theme.dyn(Theme.greenSub, Theme.darkGreenSub))
    static let greenBG    = Color(nsColor: Theme.dyn(Theme.greenBG, Theme.darkGreenBG))
    static let greenBorder = Color(nsColor: Theme.dyn(Theme.greenBorder, Theme.darkGreenBorder))
    static let coralDeep  = Color(nsColor: Theme.dyn(Theme.coralDeep, Theme.coralLight))

    // 고정 색 — 녹음 화면(항상 다크)과 브랜드
    static let inkFixed   = Color(nsColor: Theme.ink)
    static let coral      = Color(nsColor: Theme.coral)
    static let green      = Color(nsColor: Theme.green)
    static let darkPanel  = Color(nsColor: Theme.darkPanel)
    static let darkCard   = Color(nsColor: Theme.darkCard)
    static let darkLine   = Color(nsColor: Theme.darkLine)
    static let darkMuted  = Color(nsColor: Theme.darkMuted)
    static let darkText   = Color(nsColor: Theme.darkText)
    static let darkSub    = Color(nsColor: Theme.darkSub)
}

// MARK: - 로고 "말의 파형이 하나의 점(요점)으로"
//
// 시안의 SVG (viewBox 0 0 32 32):
//   <path d="M4 21 C7 8, 10.5 8, 13.5 16 C15.5 21.5, 18 21.5, 20.5 16" stroke-width="3" stroke-linecap="round"/>
//   <circle cx="26.5" cy="16" r="3"/>

enum Logo {

    static let viewBox: CGFloat = 32
    static let dotCenter = CGPoint(x: 26.5, y: 16)
    static let dotRadius: CGFloat = 3
    static let strokeWidth: CGFloat = 3

    /// y축이 아래로 향하는(SVG와 같은) 좌표계 기준 파형 경로.
    static func wave(scale s: CGFloat, offset o: CGPoint = .zero) -> NSBezierPath {
        let p = NSBezierPath()
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: o.x + x * s, y: o.y + y * s) }
        p.move(to: pt(4, 21))
        p.curve(to: pt(13.5, 16), controlPoint1: pt(7, 8), controlPoint2: pt(10.5, 8))
        p.curve(to: pt(20.5, 16), controlPoint1: pt(15.5, 21.5), controlPoint2: pt(18, 21.5))
        p.lineWidth = strokeWidth * s
        p.lineCapStyle = .round
        p.lineJoinStyle = .round
        return p
    }

    static func dot(scale s: CGFloat, offset o: CGPoint = .zero) -> NSBezierPath {
        let r = dotRadius * s
        let c = CGPoint(x: o.x + dotCenter.x * s, y: o.y + dotCenter.y * s)
        return NSBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    }

    /// 파형+점을 한 색으로 그린 정사각 이미지.
    static func mark(size: CGFloat, wave waveColor: NSColor, dot dotColor: NSColor) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            let s = size / viewBox
            waveColor.setStroke()
            wave(scale: s).stroke()
            dotColor.setFill()
            dot(scale: s).fill()
            return true
        }
    }

    /// 메뉴바 템플릿 아이콘. 시스템이 밝기에 맞춰 색을 입힌다.
    static func menuBarIcon() -> NSImage {
        let image = mark(size: 18, wave: .black, dot: .black)
        image.isTemplate = true
        return image
    }


    /// 메뉴바 아이콘의 **점 자리를 진행 고리로** 바꾼 것.
    ///
    /// 회의록은 1~2분이 걸리는데 메뉴를 닫으면 아무 표시가 없어서 멈춘 줄 안다(시안 2-1).
    /// 로고의 점이 차오르는 모양이라 브랜드와도 이어진다.
    ///
    /// ⚠️ 평소 아이콘은 **템플릿**이라 시스템이 밝기에 맞춰 단색으로 칠한다. 색을 쓰려면
    ///    템플릿을 꺼야 하고, 그러면 밝은 메뉴바와 어두운 메뉴바 양쪽에서 다 보이는 색이어야 한다.
    ///    코랄과 초록은 둘 다 중간 밝기라 양쪽에서 보인다. 파형은 시스템 색을 따라가지 못하므로
    ///    현재 메뉴바 밝기를 받아서 직접 칠한다.
    ///
    /// - Parameters:
    ///   - progress: 0~1. nil 이면 얼마나 왔는지 모르는 상태라 고리를 4분의 3만 그린다
    ///     (요약 단계는 %를 알 수 없다).
    ///   - color: 고리 색. 처리 중은 코랄, 끝나면 초록.
    ///   - dark: 메뉴바가 어두운지. 파형 색을 정하는 데 쓴다.
    /// - Parameter rotation: 고리를 돌린 각도. 가만히 있는 고리는 18pt 에서 눈에 안 띈다
    ///   ("로딩스피너가 너무 작고 안보여", 2026-09-29). 돌면 움직임으로 먼저 눈에 들어온다.
    static func menuBarIcon(progress: Double?, color: NSColor, dark: Bool,
                            rotation: Double = 0) -> NSImage {
        let size: CGFloat = 18
        // ⚠️ 점은 로고의 **오른쪽 끝**(viewBox 32 중 x=26.5)에 있다. 그 자리에 점보다 큰 고리를 그리면
        //    아이콘 폭을 넘어 잘린다(실제로 잘렸다, 2026-09-29). 그래서 가로만 넓힌 캔버스에 그린다.
        let overflow: CGFloat = 5
        let image = NSImage(size: NSSize(width: size + overflow, height: size), flipped: true) { _ in
            let s = size / viewBox
            (dark ? NSColor.white : NSColor.black).withAlphaComponent(0.85).setStroke()
            let wavePath = wave(scale: s)
            wavePath.stroke()

            let center = CGPoint(x: dotCenter.x * s, y: dotCenter.y * s)
            // ⚠️ 메뉴바 아이콘은 18pt 다. 처음엔 점 크기에 맞춰 가늘게 그렸더니 "안 보인다"는 말을 들었다.
            //    점보다 확실히 크고 굵게 그려야 읽힌다.
            // 1.7배로 했더니 왼쪽이 파형 꼬리에 붙었다. 파형과 간격이 보이는 선까지만 키운다.
            let radius = dotRadius * s * 1.5
            let width = max(2.0, dotRadius * s * 1.0)

            // 바탕 고리 — 얼마나 남았는지 보이게 깐다. 너무 흐리면 0% 일 때 아무것도 없어 보인다.
            color.withAlphaComponent(0.4).setStroke()
            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = width
            track.stroke()

            // 찬 만큼 — 12시에서 시계 방향으로.
            color.setStroke()
            let filled = NSBezierPath()
            // ⚠️ 0% 를 그대로 그리면 채워진 곳이 없어 멈춘 것처럼 보인다. 최소한 한 조각은 채운다.
            let sweep = (progress.map { min(max($0, 0.08), 1) } ?? 0.75) * 360
            let start = 90 - rotation
            filled.appendArc(withCenter: center, radius: radius,
                             startAngle: start, endAngle: start - sweep, clockwise: true)
            filled.lineWidth = width
            filled.lineCapStyle = .round
            filled.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }


    // MARK: - 메뉴바 로더

    /// 파형 경로를 잘게 편 점들과 누적 길이. `NSBezierPath` 에는 SwiftUI 의 `trim` 이 없어서
    /// 직접 잘라야 한다. viewBox(32) 좌표로 한 번만 계산해 두고 그릴 때 배율만 곱한다.
    private static let flatWave: (points: [CGPoint], lengths: [CGFloat], total: CGFloat) = {
        let flat = wave(scale: 1).flattened
        var points: [CGPoint] = []
        var element = [NSPoint](repeating: .zero, count: 3)
        for i in 0..<flat.elementCount {
            switch flat.element(at: i, associatedPoints: &element) {
            case .moveTo, .lineTo: points.append(element[0])
            default: break
            }
        }
        var lengths: [CGFloat] = [0]
        var total: CGFloat = 0
        for i in 1..<max(points.count, 1) {
            total += hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y)
            lengths.append(total)
        }
        return (points, lengths, total)
    }()

    /// 전체 길이의 `from`~`to`(0~1) 구간만 남긴 경로.
    private static func trimmedWave(from: Double, to: Double, scale s: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        let (points, lengths, total) = flatWave
        guard points.count > 1, total > 0, to > from else { return path }
        let a = CGFloat(from) * total, b = CGFloat(to) * total
        var started = false
        for i in 1..<points.count {
            let l0 = lengths[i - 1], l1 = lengths[i]
            guard l1 > a, l0 < b else { continue }
            // 구간이 잘리는 자리는 두 점 사이를 비례로 나눠 찾는다.
            func at(_ length: CGFloat) -> CGPoint {
                let t = l1 > l0 ? (length - l0) / (l1 - l0) : 0
                return CGPoint(x: points[i - 1].x + (points[i].x - points[i - 1].x) * t,
                               y: points[i - 1].y + (points[i].y - points[i - 1].y) * t)
            }
            let p0 = at(max(l0, a)), p1 = at(min(l1, b))
            if !started { path.move(to: CGPoint(x: p0.x * s, y: p0.y * s)); started = true }
            path.line(to: CGPoint(x: p1.x * s, y: p1.y * s))
        }
        return path
    }

    /// 메뉴바에 그리는 로고 로더. 팝오버의 `BreflyLoader` 와 같은 96프레임 루프다 —
    /// 파형이 그려졌다 지워지고 점이 튀어나온다. 돌아가는 고리보다 이쪽이 브랜드에 맞는다.
    ///
    /// ⚠️ 진행률은 여기 없다. 이 애니메이션은 "돌아가고 있다"만 말한다.
    ///    얼마나 왔는지는 아이콘 옆의 퍼센트 글자가 맡는다.
    static func menuBarLoader(frame f: Double, dark: Bool) -> NSImage {
        let size: CGFloat = 18
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            let s = size / viewBox
            let trimEnd = ramp(f, 0, 35, 0, 1, easeInOut)
            let trimStart = ramp(f, 55, 75, 0, 1, easeInOut)
            let dotOpacity = f < 80 ? ramp(f, 37, 45, 0, 1, easeOut) : ramp(f, 80, 90, 1, 0, easeIn)
            let dotScale: Double = {
                if f < 49 { return ramp(f, 37, 49, 0, 1.3, easeOut) }
                if f < 55 { return ramp(f, 49, 55, 1.3, 1, easeInOut) }
                if f < 80 { return 1 }
                return ramp(f, 80, 90, 1, 0, easeIn)
            }()

            let ink = dark ? NSColor.white : NSColor(hex: 0x16181d)
            ink.setStroke()
            let path = trimmedWave(from: trimStart, to: max(trimStart, trimEnd), scale: s)
            path.lineWidth = strokeWidth * s
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()

            if dotOpacity > 0.01, dotScale > 0.01 {
                Theme.coral.withAlphaComponent(dotOpacity).setFill()
                let r = dotRadius * s * dotScale
                let c = CGPoint(x: dotCenter.x * s, y: dotCenter.y * s)
                NSBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)).fill()
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func ramp(_ f: Double, _ f0: Double, _ f1: Double, _ v0: Double, _ v1: Double,
                             _ ease: (Double) -> Double) -> Double {
        if f <= f0 { return v0 }
        if f >= f1 { return v1 }
        return v0 + (v1 - v0) * ease((f - f0) / (f1 - f0))
    }
    private static func easeInOut(_ t: Double) -> Double { t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2 }
    private static func easeOut(_ t: Double) -> Double { 1 - pow(1 - t, 3) }
    private static func easeIn(_ t: Double) -> Double { t * t * t }

    /// 앱 아이콘: 잉크 블랙 둥근 사각형 + 흰 파형 + 코랄 점.
    static func appIcon(size: CGFloat = 512) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            let inset = size * 0.1
            let box = rect.insetBy(dx: inset, dy: inset)
            let bg = NSBezierPath(roundedRect: box, xRadius: box.width * 0.225, yRadius: box.width * 0.225)
            Theme.ink.setFill()
            bg.fill()

            // 파형은 아이콘 폭의 62%를 쓴다.
            let s = box.width * 0.62 / viewBox
            let o = CGPoint(x: box.midX - viewBox * s / 2, y: box.midY - viewBox * s / 2)
            NSColor.white.setStroke()
            wave(scale: s, offset: o).stroke()
            Theme.coral.setFill()
            dot(scale: s, offset: o).fill()
            return true
        }
    }
}

// MARK: - SwiftUI 로고

struct LogoWave: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / Logo.viewBox
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        var p = Path()
        p.move(to: pt(4, 21))
        p.addCurve(to: pt(13.5, 16), control1: pt(7, 8), control2: pt(10.5, 8))
        p.addCurve(to: pt(20.5, 16), control1: pt(15.5, 21.5), control2: pt(18, 21.5))
        return p
    }
}

struct LogoMark: View {
    var size: CGFloat = 24
    var wave: Color = .ink
    var dot: Color = .coral

    var body: some View {
        let s = size / Logo.viewBox
        ZStack(alignment: .topLeading) {
            LogoWave()
                .stroke(wave, style: StrokeStyle(lineWidth: Logo.strokeWidth * s, lineCap: .round, lineJoin: .round))
            Circle()
                .fill(dot)
                .frame(width: Logo.dotRadius * 2 * s, height: Logo.dotRadius * 2 * s)
                .offset(x: (Logo.dotCenter.x - Logo.dotRadius) * s,
                        y: (Logo.dotCenter.y - Logo.dotRadius) * s)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - 로더 (brefly-loader.json 로띠를 SwiftUI 로 옮김)
//
// 120×120, 30fps, 96프레임 루프. 우리 로고 경로를 3.75배 한 좌표라 LogoWave 를 그대로 쓴다.
//   파형: trim end 0→100 (0~35f), trim start 0→100 (55~75f)
//   점:   불투명도 0→100 (37~45f), 100→0 (80~90f) · 크기 0→130% (37~49f) →100% (49~55f) →0 (80~90f)

struct BreflyLoader: View {
    var size: CGFloat = 56
    var wave: Color = .ink
    var dot: Color = .coral
    /// 미리보기용: 지정하면 그 프레임에 멈춘다
    var fixedFrame: Double? = nil

    private let fps: Double = 30
    private let frames: Double = 96
    private let start = Date()

    var body: some View {
        TimelineView(.animation) { context in
            let elapsed = context.date.timeIntervalSince(start)
            let f = fixedFrame ?? (elapsed * fps).truncatingRemainder(dividingBy: frames)
            let s = size / Logo.viewBox
            let trimEnd = ramp(f, 0, 35, 0, 1, easeInOut)
            let trimStart = ramp(f, 55, 75, 0, 1, easeInOut)
            let dotOpacity = f < 80 ? ramp(f, 37, 45, 0, 1, easeOut) : ramp(f, 80, 90, 1, 0, easeIn)
            let dotScale: Double = {
                if f < 49 { return ramp(f, 37, 49, 0, 1.3, easeOut) }
                if f < 55 { return ramp(f, 49, 55, 1.3, 1, easeInOut) }
                if f < 80 { return 1 }
                return ramp(f, 80, 90, 1, 0, easeIn)
            }()

            ZStack(alignment: .topLeading) {
                LogoWave()
                    .trim(from: trimStart, to: max(trimStart, trimEnd))
                    .stroke(wave, style: StrokeStyle(lineWidth: Logo.strokeWidth * s, lineCap: .round, lineJoin: .round))
                Circle()
                    .fill(dot)
                    .frame(width: Logo.dotRadius * 2 * s, height: Logo.dotRadius * 2 * s)
                    .scaleEffect(dotScale)
                    .opacity(dotOpacity)
                    .offset(x: (Logo.dotCenter.x - Logo.dotRadius) * s,
                            y: (Logo.dotCenter.y - Logo.dotRadius) * s)
            }
            .frame(width: size, height: size)
        }
    }

    private func ramp(_ f: Double, _ f0: Double, _ f1: Double, _ v0: Double, _ v1: Double,
                      _ ease: (Double) -> Double) -> Double {
        if f <= f0 { return v0 }
        if f >= f1 { return v1 }
        return v0 + (v1 - v0) * ease((f - f0) / (f1 - f0))
    }
    private func easeInOut(_ t: Double) -> Double { t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2 }
    private func easeOut(_ t: Double) -> Double { 1 - pow(1 - t, 3) }
    private func easeIn(_ t: Double) -> Double { t * t * t }
}

struct AudioFileIcon: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * s, y: rect.minY + y * s)
        }
        var path = Path()

        // 문서 — 오른쪽 위 귀퉁이를 접는다
        path.move(to: p(5, 2.5))
        path.addLine(to: p(14, 2.5))
        path.addLine(to: p(19, 7.5))
        path.addLine(to: p(19, 21.5))
        path.addLine(to: p(5, 21.5))
        path.closeSubpath()
        path.move(to: p(14, 2.5))
        path.addLine(to: p(14, 7.5))
        path.addLine(to: p(19, 7.5))

        // 헤드폰 — 머리띠와 양쪽 귀
        path.addArc(center: p(12, 15.2), radius: 4.1 * s,
                    startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
        for x in [7.9, 16.1] as [CGFloat] {
            path.addRoundedRect(in: CGRect(x: p(x - 0.9, 15).x, y: p(x - 0.9, 15).y,
                                           width: 1.9 * s, height: 3.4 * s),
                                cornerSize: CGSize(width: 0.95 * s, height: 0.95 * s))
        }
        return path
    }
}
