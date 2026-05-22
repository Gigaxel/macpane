import AppKit
import QuartzCore

final class WorkspaceSlideAnimator: NSObject {
    private let duration: TimeInterval
    private let frameRate: Int
    private let screen: NSScreen?
    private let shouldContinue: () -> Bool
    private let onFrame: (CGFloat) -> Void
    private let onFinish: () -> Void
    private var displayLink: NSObject?
    private var timer: Timer?
    private var startTime = CACurrentMediaTime()
    private var didFinish = false
    init(
        duration: TimeInterval,
        frameRate: Int,
        screen: NSScreen?,
        shouldContinue: @escaping () -> Bool,
        onFrame: @escaping (CGFloat) -> Void,
        onFinish: @escaping () -> Void
    ) {
        self.duration = duration
        self.frameRate = frameRate
        self.screen = screen
        self.shouldContinue = shouldContinue
        self.onFrame = onFrame
        self.onFinish = onFinish
    }
    func start() {
        startTime = CACurrentMediaTime()
        if #available(macOS 14.0, *), let screen {
            let displayLink = screen.displayLink(target: self, selector: #selector(displayLinkDidTick(_:)))
            let rate = Float(max(frameRate, 1))
            displayLink.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
            displayLink.add(to: .main, forMode: .common)
            self.displayLink = displayLink
            return
        }
        let interval = 1 / TimeInterval(max(frameRate, 1))
        let timer = Timer(timeInterval: interval, target: self, selector: #selector(timerDidTick(_:)), userInfo: nil, repeats: true)
        timer.tolerance = 0
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
    func finishImmediately() {
        guard !didFinish else { return }
        invalidate()
        onFrame(1)
        finish()
    }
    func cancel() {
        guard !didFinish else { return }
        didFinish = true
        invalidate()
    }
    @available(macOS 14.0, *)
    @objc private func displayLinkDidTick(_ displayLink: CADisplayLink) {
        tick(now: CACurrentMediaTime())
    }
    @objc private func timerDidTick(_ timer: Timer) {
        tick(now: CACurrentMediaTime())
    }
    private func tick(now: CFTimeInterval) {
        guard !didFinish else { return }
        guard shouldContinue() else {
            cancel()
            return
        }
        let progress = min(max((now - startTime) / duration, 0), 1)
        onFrame(CGFloat(progress))
        if progress >= 1 {
            finish()
        }
    }
    private func finish() {
        guard !didFinish else { return }
        didFinish = true
        invalidate()
        onFinish()
    }
    private func invalidate() {
        if #available(macOS 14.0, *), let displayLink = displayLink as? CADisplayLink {
            displayLink.invalidate()
        }
        displayLink = nil
        timer?.invalidate()
        timer = nil
    }
    deinit {
        invalidate()
    }
}
