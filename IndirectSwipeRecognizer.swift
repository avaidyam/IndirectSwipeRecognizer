import Cocoa
import CoreFoundation
import CoreGraphics
@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {
    @IBOutlet weak var window: NSWindow!
    private var layer = CALayer()
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        NSGestureRecognizer.wantsIndirectTouches = true
        
        self.layer.bounds = CGRect(x: 0, y: 0, width: 50, height: 50)
        self.layer.cornerRadius = 3.0
        self.layer.backgroundColor = NSColor.systemRed.cgColor
        self.window.contentView!.layer?.addSublayer(self.layer)
    }
    @IBAction func test(_ sender: TouchSwipeRecognizer) {
        print(sender.state.rawValue, sender.velocity, sender.value)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let parent = self.layer.superlayer!.bounds
        self.layer.position.x += sender.delta.dx * parent.width
        self.layer.position.y += sender.delta.dy * parent.height
        CATransaction.commit()
    }
}

/// Receives system events. See `CGEventTap`.
public final class SystemEventListener {
    
    /// The underlying port.
    fileprivate private(set) var port: CFMachPort? = nil
    
    /// The underlying runloop source.
    fileprivate private(set) var source: CFRunLoopSource? = nil
    
    /// The events the `SystemEventListener` will receive.
    public let events: [CGEventType]
    
    /// The actions the `SystemEventListener` will invoke upon event receipt.
    public let action: @convention(block) (NSEvent) -> ()
    
    /// Whether the listener will receive system events from the specified mask.
    public var isEnabled: Bool = true {
        didSet {
            CGEvent.tapEnable(tap: self.port!, enable: self.isEnabled)
        }
    }
    
    /// Create a new `SystemEventListener` at the directed point.
    /// Create a notification center observer to handle the received events.
    public init(for events: CGEventType..., action: @escaping @convention(block) (NSEvent) -> ()) {
        self.events = events
        self.action = action
        let mask: CGEventMask = events.map { 1 << $0.rawValue }.reduce(0, |)

        let callback: CGEventTapCallBack = { _, type, _cg, info in
            let this = unsafeBitCast(info!, to: SystemEventListener.self)
            
            switch type {
            case .tapDisabledByTimeout: fallthrough
            case .tapDisabledByUserInput: // auto-reenabled
                CGEvent.tapEnable(tap: this.port!, enable: this.isEnabled)
                break
            default:
                guard let event = NSEvent(cgEvent: _cg) else { break }
                this.action(event)
            }
            return nil
        }
        
        self.port = CGEvent.tapCreate(tap: .cgAnnotatedSessionEventTap,
                                      place: .tailAppendEventTap,
                                      options: .listenOnly, /*.defaultTap*/
                                      eventsOfInterest: mask,
                                      callback: callback,
                                      userInfo: unsafeBitCast(self, to: UnsafeMutableRawPointer.self))!
        self.source = CFMachPortCreateRunLoopSource(nil, self.port, 0)
    }
}

public extension RunLoop {
    
    ///
    public func add(_ listener: SystemEventListener, to modes: RunLoopMode...) {
        let cf = self.getCFRunLoop()
        for mode in modes {
            CFRunLoopAddSource(cf, listener.source, CFRunLoopMode(mode.rawValue as CFString))
        }
    }
    
    ///
    public func remove(_ listener: SystemEventListener, from modes: RunLoopMode...) {
        let cf = self.getCFRunLoop()
        for mode in modes {
            CFRunLoopRemoveSource(cf, listener.source, CFRunLoopMode(mode.rawValue as CFString))
        }
    }
}

public extension CGEventType {
    
    /// All touches are recieved for this event type.
    public static let touches = CGEventType(rawValue: 29)!
    
    /// The Mission Control up/down swipe.
    public static let fluidGestureSwipe = CGEventType(rawValue: 30)!
    
    /// The Notification Center edge swipe.
    public static let fluidEdgeSwipe = CGEventType(rawValue: 31)!
}


public extension RunLoopMode {
    
    /// The AppKit event tracking `RunLoopMode`.
    public static let eventTrackingMode = RunLoopMode("NSEventTrackingRunLoopMode")
}

/// Dispatch indirect touch events to `NSGestureRecognizer`s.
/// TODO: It's better to set `NSWindow.gestureMask` and do this in `sendEvent:`.
public final class IndirectTouchTracker {
    private var listener: SystemEventListener? = nil
    
    public init() {
        self.listener = SystemEventListener(for: .touches) {
            self.dispatch($0)
        }
        DispatchQueue.main.async {
            RunLoop.current.add(self.listener!, to: .defaultRunLoopMode, .eventTrackingMode)
        }
    }
    
    /// Dispatch the `event` to any interested `NSGestureRecognizer`s.
    private func dispatch(_ event: NSEvent) {
        guard event.touches(matching: .any, in: nil).count >= 2 else { return } /* two-finger swipe only */
        guard   let window = NSApp.window(withWindowNumber: event.windowNumber),
                let view = (window.value(forKey: "borderView") as! NSView)
                    .hitTest(event.locationInWindow)
        else { return } /* locate the specific view under the pointer */
        
        event.touches(matching: .any, in: nil).forEach { $0.setValue(view, forKey: "view") }
        view.gestureRecognizers
            .filter { ($0 as TouchableRecognizer).wantsIndirectTouches ?? false }
            .forEach { g in
                if event.touches(matching: .began, in: nil).count > 0 {
                    let sel = Selector("touchesBeganWithEvent" + ":")
                    if g.responds(to: sel) { g.perform(sel, with: event) }
                }
                if event.touches(matching: .moved, in: nil).count > 0 {
                    let sel = Selector("touchesMovedWithEvent" + ":")
                    if g.responds(to: sel) { g.perform(sel, with: event) }
                }
                if event.touches(matching: .ended, in: nil).count > 0 {
                    let sel = Selector("touchesEndedWithEvent" + ":")
                    if g.responds(to: sel) { g.perform(sel, with: event) }
                }
                if event.touches(matching: .cancelled, in: nil).count > 0 {
                    let sel = Selector("touchesCancelledWithEvent" + ":")
                    if g.responds(to: sel) { g.perform(sel, with: event) }
                }
            }
    }
}

public extension NSGestureRecognizer {
    
    /// `NSGestureRecognizer`s that request indirect touches (`wantsIndirectTouches`)
    /// will receive them if the value of this property is `true`.
    public class var wantsIndirectTouches: Bool {
        get { return _tracker != nil }
        set {
            if _tracker != nil && !newValue {
                _tracker = nil
            } else if _tracker == nil && newValue {
                _tracker = IndirectTouchTracker()
            }
        }
    }
}
fileprivate var _tracker: IndirectTouchTracker? = nil


@objc public protocol TouchableRecognizer {
    @objc optional var wantsIndirectTouches: Bool { get }
}
extension NSGestureRecognizer: TouchableRecognizer {}

///
public class TouchSwipeRecognizer: NSGestureRecognizer {
    public var wantsIndirectTouches: Bool { return true }
    
    /// Used as the inset from horizontal and vertical edges for detection of a swipe.
    /// It is automatically clamped to [0.0, 1.0].
    public var detectionInset = CGSize(width: 0.5, height: 0.5) {
        didSet {
            self.detectionInset = CGSize(width: min(max(self.detectionInset.width, 0.0), 1.0),
                                         height: min(max(self.detectionInset.height, 0.0), 1.0))
        }
    }
    
    /// The average current swipe position of the fingers on the trackpad.
    /// If observing a horizontal swipe, use the `x` value, and if observing
    /// a vertical swipe, use the `y` value. Negative values indicate closer
    /// to the origin (0, 0) of the trackpad in cartesian coordinates.
    public private(set) var value: CGPoint = .zero {
        didSet {
            self.delta = CGVector(dx: self.value.x - oldValue.x, dy: self.value.y - oldValue.y)
        }
    }
    
    /// The change in touch position since the previous touch event.
    /// See `value` for more details.
    public private(set) var delta: CGVector = .zero
    
    /// The internal raw time when the touch event was received.
    private var _time: CFTimeInterval = 0.0 {
        didSet { self.velocity = self._time - oldValue }
    }
    
    /// The duration taken to observe the change since the previous touch event.
    /// A negative value is invalid and implies no event was received.
    public private(set) var velocity: CFTimeInterval = -1.0
    
    ///
    private var initialTouches: Set<NSTouch> = []
    
    public override func reset() {
        self.value = .zero
        self.delta = .zero
        self._time = 0.0
        self.velocity = -1.0
        self.initialTouches = []
    }
    
    public override func touchesBegan(with event: NSEvent) {
        guard event.touches(matching: .touching, in: nil).count != 0 else { return } /* already started */
        self.initialTouches = event.touches(matching: .any, in: nil)
        self._time = CACurrentMediaTime()
        self.state = .began
    }
    
    public override func touchesMoved(with event: NSEvent) {
        guard event.touches(matching: .any, in: nil).count == 2 else {
            self.state = .failed; return
        }
        
        let i = self.avg(of: self.initialTouches)
        let o = self.avg(of: event.touches(matching: .any, in: nil))
        self.value = CGPoint(x: (o.x - i.x), y: (o.y - i.y))
        self._time = CACurrentMediaTime()
        self.state = .changed
    }
    
    public override func touchesEnded(with event: NSEvent) {
        guard event.touches(matching: .touching, in: nil).count == 0 else { return }
        self._time = CACurrentMediaTime()
        self.state = .ended
    }
    
    public override func touchesCancelled(with event: NSEvent) {
        guard event.touches(matching: .touching, in: nil).count == 0 else { return }
        self._time = CACurrentMediaTime()
        self.state = .cancelled
    }
    
    /// Compute the average touch point of the set.
    private func avg(of touches: Set<NSTouch>) -> CGPoint {
        let total = CGFloat(touches.count)
        let sum = touches
            .map { $0.normalizedPosition }
            .reduce(.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: (sum.x / total) / (1.0 - self.detectionInset.width),
                       y: (sum.y / total) / (1.0 - self.detectionInset.height))
    }
}
