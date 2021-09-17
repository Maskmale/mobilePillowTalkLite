//
//  iOSTerminalView.swift
//
// This is the AppKit version of the TerminalView and holds the state
// variables in the `TerminalView` class, but as much of the terminal
// implementation details live in the Apple/AppleTerminalView which
// contains the shared AppKit/UIKit code
//
//  The indicator "//X" means that this code was commented out from the Mac version for the sake of
//  porting and need to be audited.
//  Created by Miguel de Icaza on 3/4/20.
//

#if os(iOS) || os(tvOS)
import Foundation
import UIKit
import CoreText
import CoreGraphics
import os

#if os(iOS)
@available(iOS 14.0, *)
internal var log: Logger = Logger(subsystem: "org.tirania.SwiftTerm", category: "msg")
#else
@available(tvOS 14.0, *)
internal var log: Logger = Logger(subsystem: "org.tirania.SwiftTerm", category: "msg")
#endif

/**
 * TerminalView provides an UIKit front-end to the `Terminal` termininal emulator.
 * It is up to a subclass to either wire the terminal emulator to a remote terminal
 * via some socket, to an application that wants to run with terminal emulation, or
 * wiring this up to a pseudo-terminal.
 *
 * Users are notified of interesting events in their implementation of the `TerminalViewDelegate`
 * methods - an instance must be provided to the constructor of `TerminalView`.
 *
 * Call the `getTerminal` method to get a reference to the underlying `Terminal` that backs this
 * view.
 *
 * Use the `configureNativeColors()` to set the defaults colors for the view to match the OS
 * defaults, otherwise, this uses its own set of defaults colors.
 */
open class TerminalView: UIScrollView, UITextInputTraits, UIKeyInput, UIScrollViewDelegate {
    
    struct FontSet {
        public let normal: UIFont
        let bold: UIFont
        let italic: UIFont
        let boldItalic: UIFont
        
        static var defaultFont: UIFont {
            UIFont.monospacedSystemFont (ofSize: 12, weight: .regular)
        }
        
        public init(font baseFont: UIFont) {
            self.normal = baseFont
            self.bold = UIFont (descriptor: baseFont.fontDescriptor.withSymbolicTraits ([.traitBold])!, size: 0)
            self.italic = UIFont (descriptor: baseFont.fontDescriptor.withSymbolicTraits ([.traitItalic])!, size: 0)
            self.boldItalic = UIFont (descriptor: baseFont.fontDescriptor.withSymbolicTraits ([.traitItalic, .traitBold])!, size: 0)
        }
        
        // Expected by the shared rendering code
        func underlinePosition () -> CGFloat
        {
            return -1.2
        }
        
        // Expected by the shared rendering code
        func underlineThickness () -> CGFloat
        {
            return 0.63
        }
    }
    
    /**
     * The delegate that the TerminalView uses to interact with its hosting
     */
    public weak var terminalDelegate: TerminalViewDelegate?
    
    var accessibility: AccessibilityService = AccessibilityService()
    var search: SearchService!
    var debug: UIView?
    var pendingDisplay: Bool = false
    var cellDimension: CellDimension!
    var caretView: CaretView!
    var terminal: Terminal!
    var allowMouseReporting: Bool { terminalAccessory?.touchOverride ?? false }
    var selection: SelectionService!
    var attrStrBuffer: CircularList<ViewLineInfo>!
    var images:[(image: TerminalImage, col: Int, row: Int)] = []

    // Attribute dictionary, maps a console attribute (color, flags) to the corresponding dictionary
    // of attributes for an NSAttributedString
    var attributes: [Attribute: [NSAttributedString.Key:Any]] = [:]
    var urlAttributes: [Attribute: [NSAttributedString.Key:Any]] = [:]

    // Timer to display the terminal buffer
    var link: CADisplayLink!
    // Cache for the colors in the 0..255 range
    var colors: [UIColor?] = Array(repeating: nil, count: 256)
    var trueColors: [Attribute.Color:UIColor] = [:]
    var transparent = TTColor.transparent ()
    
    // UITextInput support starts
    public lazy var tokenizer: UITextInputTokenizer = UITextInputStringTokenizer (textInput: self) // TerminalInputTokenizer()
    
    // We use this as temporary storage for UITextInput, which we send to the terminal on demand
    var textInputStorage: [Character] = []
    
    // This tracks the marked text, part of the UITextInput protocol, which is used to flag temporary data entry, that might
    // be removed afterwards by the input system (input methods will insert approximiations, mark and change on demand)
    var _markedTextRange: xTextRange?

    // The input delegate is part of UITextInput, and we notify it of changes.
    public weak var inputDelegate: UITextInputDelegate?
    // This tracks the selection in the textInputStorage, it is not the same as our global selection, it is temporary
    var _selectedTextRange: xTextRange = xTextRange(0, 0)

    var fontSet: FontSet
    /// The font to use to render the terminal
    public var font: UIFont {
        get {
            return fontSet.normal
        }
        set {
            fontSet = FontSet (font: newValue)
            resetFont();
        }
    }
    
    public init(frame: CGRect, font: UIFont?) {
        self.fontSet = FontSet (font: font ?? FontSet.defaultFont)
        super.init (frame: frame)
        setup()
    }
    
    public override init (frame: CGRect)
    {
        self.fontSet = FontSet (font: FontSet.defaultFont)
        super.init (frame: frame)
        setup()
    }
    
    public required init? (coder: NSCoder)
    {
        self.fontSet = FontSet (font: FontSet.defaultFont)
        super.init (coder: coder)
        setup()
    }
          
    func setup()
    {
        setupDisplayUpdates ();
        setupOptions ()
        setupGestures ()
        setupAccessoryView ()
    }

    func setupDisplayUpdates ()
    {
        link = CADisplayLink(target: self, selector: #selector(step))
            
        link.add(to: .current, forMode: .default)
        suspendDisplayUpdates()
    }
    
    @objc
    func step(displaylink: CADisplayLink) {
        updateDisplay()
    }

    func startDisplayUpdates()
    {
        link.isPaused = false
    }
    
    func suspendDisplayUpdates()
    {
        link.isPaused = true
    }
    
    @objc func pasteCmd(_ sender: Any?) {
        #if os(iOS)
        if let start = UIPasteboard.general.string {
            send(txt: start)
            queuePendingDisplay()
        }
        #endif
    }

    @objc func copyCmd(_ sender: Any?) {
        #if os(iOS)
        UIPasteboard.general.string = selection.getSelectedText()
        #endif
    }

    @objc func resetCmd(_ sender: Any?) {
        terminal.cmdReset()
        queuePendingDisplay()
    }
    
    @objc func longPress (_ gestureRecognizer: UILongPressGestureRecognizer)
    {
        #if os(iOS)
        
         if gestureRecognizer.state == .began {
            self.becomeFirstResponder()
            //self.viewForReset = gestureRecognizer.view

            var items: [UIMenuItem] = []
            
            if selection.active {
                items.append(UIMenuItem(title: "Copy", action: #selector(copyCmd)))
            }
            if UIPasteboard.general.hasStrings {
                items.append(UIMenuItem(title: "Paste", action: #selector(pasteCmd)))
            }
            items.append (UIMenuItem(title: "Reset", action: #selector(resetCmd)))
            
            // Configure the shared menu controller
            let menuController = UIMenuController.shared
            menuController.menuItems = items
            
            // TODO:
            //  - If nothing is selected, offer Select, Select All
            //  - If something is selected, offer copy, look up, share, "Search on StackOverflow"

            // Set the location of the menu in the view.
            let location = gestureRecognizer.location(in: gestureRecognizer.view)
            let menuLocation = CGRect(x: location.x, y: location.y, width: 0, height: 0)
            //menuController.setTargetRect(menuLocation, in: gestureRecognizer.view!)
            menuController.showMenu(from: gestureRecognizer.view!, rect: menuLocation)
            
          }
        #endif
    }
    
    /// This controls whether the backspace should send ^? or ^H, the default is ^?
    public var backspaceSendsControlH: Bool = false
    
    func calculateTapHit (gesture: UIGestureRecognizer) -> Position
    {
        let point = gesture.location(in: self)
        let col = Int (point.x / cellDimension.width)
        let row = Int (point.y / cellDimension.height)
        if row < 0 {
            return Position(col: 0, row: 0)
        }
        return Position(col: min (max (0, col), terminal.cols-1), row: min (row, terminal.rows-1))
    }

    func encodeFlags (release: Bool) -> Int
    {
        let encodedFlags = terminal.encodeButton(
            button: 1,
            release: release,
            shift: false,
            meta: false,
            control: terminalAccessory?.controlModifier ?? false)
        terminalAccessory?.controlModifier = false
        return encodedFlags
    }
    
    func sharedMouseEvent (gestureRecognizer: UIGestureRecognizer, release: Bool)
    {
        let hit = calculateTapHit(gesture: gestureRecognizer)
        terminal.sendEvent(buttonFlags: encodeFlags (release: release), x: hit.col, y: hit.row)
    }
    
    #if true
    #endif

    @objc func singleTap (_ gestureRecognizer: UITapGestureRecognizer)
    {
        if isFirstResponder {
            guard gestureRecognizer.view != nil else { return }
                 
            if gestureRecognizer.state != .ended {
                return
            }
         
            if allowMouseReporting && terminal.mouseMode.sendButtonPress() {
                sharedMouseEvent(gestureRecognizer: gestureRecognizer, release: false)

                if terminal.mouseMode.sendButtonRelease() {
                    sharedMouseEvent(gestureRecognizer: gestureRecognizer, release: true)
                }
            }
            queuePendingDisplay()
        } else {
            becomeFirstResponder ()
        }
    }
    
    @objc func doubleTap (_ gestureRecognizer: UITapGestureRecognizer)
    {
        guard gestureRecognizer.view != nil else { return }
               
        if gestureRecognizer.state != .ended {
            return
        }
        
        if allowMouseReporting && terminal.mouseMode.sendButtonPress() {
            sharedMouseEvent(gestureRecognizer: gestureRecognizer, release: false)
            
            if terminal.mouseMode.sendButtonRelease() {
                sharedMouseEvent(gestureRecognizer: gestureRecognizer, release: true)
            }
            return
        } else {
            let hit = calculateTapHit(gesture: gestureRecognizer)
            selection.selectWordOrExpression(at: Position(col: hit.col, row: hit.row + terminal.buffer.yDisp), in: terminal.buffer)
            queuePendingDisplay()
        }
    }
    
    @objc func pan (_ gestureRecognizer: UIPanGestureRecognizer)
    {
        guard gestureRecognizer.view != nil else { return }
        if allowMouseReporting {
            switch gestureRecognizer.state {
            case .began:
                // send the initial tap
                if terminal.mouseMode.sendButtonPress() {
                    sharedMouseEvent(gestureRecognizer: gestureRecognizer, release: false)
                }
            case .ended, .cancelled:
                if terminal.mouseMode.sendButtonRelease() {
                    sharedMouseEvent(gestureRecognizer: gestureRecognizer, release: true)
                }
            case .changed:
                if terminal.mouseMode.sendButtonTracking() {
                    let hit = calculateTapHit(gesture: gestureRecognizer)
                    terminal.sendMotion(buttonFlags: encodeFlags(release: false), x: hit.col, y: hit.row)
                }
            default:
                break
            }
        } else {
            switch gestureRecognizer.state {
            case .began:
                let hit = calculateTapHit(gesture: gestureRecognizer)
                //print ("Starting at \(hit.col), \(hit.row)")
                selection.startSelection(row: hit.row, col: hit.col)
                queuePendingDisplay()
            case .changed:
                let hit = calculateTapHit(gesture: gestureRecognizer)
                //print ("Extending to \(hit.col), \(hit.row)")
                selection.shiftExtend(row: hit.row, col: hit.col)
                queuePendingDisplay()
            case .ended:
                break
            case .cancelled:
                selection.active = false
            default:
                break
            }
        }
    }
    
    func setupGestures ()
    {
        let longPress = UILongPressGestureRecognizer (target: self, action: #selector(longPress(_:)))
        longPress.minimumPressDuration = 0.7
        addGestureRecognizer(longPress)
        
        let singleTap = UITapGestureRecognizer (target: self, action: #selector(singleTap(_:)))
        addGestureRecognizer(singleTap)
        
        let doubleTap = UITapGestureRecognizer (target: self, action: #selector(doubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)

        let pan = UIPanGestureRecognizer (target: self, action: #selector(pan(_:)))
        addGestureRecognizer(pan)
    }

    var _inputAccessory: UIView?
    var _inputView: UIView?
    
    ///
    /// You can set this property to a UIView to be your input accessory, by default
    /// this is an instance of `TerminalAccessory`
    ///
    public override var inputAccessoryView: UIView? {
        get { _inputAccessory }
        set {
            _inputAccessory = newValue
        }
    }

    ///
    /// You can set this property to a UIView to be your input accessory, by default
    /// this is an instance of `TerminalAccessory`
    ///
    public override var inputView: UIView? {
        get { _inputView }
        set {
            _inputView = newValue
        }
    }

    /// Returns the inputaccessory in case it is a TerminalAccessory and we can use it
    var terminalAccessory: TerminalAccessory? {
        get {
            _inputAccessory as? TerminalAccessory
        }
    }

    func setupAccessoryView ()
    {
        let ta = TerminalAccessory(frame: CGRect(x: 0, y: 0, width: frame.width, height: 36),
                                              inputViewStyle: .keyboard)
        ta.sizeToFit()
        ta.terminalView = self
        inputAccessoryView = ta
        //inputAccessoryView?.autoresizingMask = .flexibleHeight
    }
    
    func setupOptions ()
    {
        setupOptions(width: bounds.width, height: bounds.height)
        layer.backgroundColor = nativeBackgroundColor.cgColor
        nativeBackgroundColor = UIColor.clear
    }
    
    var _nativeFg, _nativeBg: TTColor!
    var settingFg = false, settingBg = false
    /**
     * This will set the native foreground color to the specified native color (UIColor or NSColor)
     * and will have this reflected into the underlying's terminal `foregroundColor` and
     * `backgroundColor`
     */
    public var nativeForegroundColor: UIColor {
        get { _nativeFg }
        set {
            if settingFg { return }
            settingFg = true
            _nativeFg = newValue
            terminal.foregroundColor = nativeForegroundColor.getTerminalColor ()
            settingFg = false
        }
    }
    
    /**
     * This will set the native foreground color to the specified native color (UIColor or NSColor)
     * and will have this reflected into the underlying's terminal `foregroundColor` and
     * `backgroundColor`
     */
    public var nativeBackgroundColor: UIColor {
        get { _nativeBg }
        set {
            if settingBg { return }
            settingBg = true
            _nativeBg = newValue
            terminal.backgroundColor = nativeBackgroundColor.getTerminalColor ()
            colorsChanged()
            settingBg = false
        }
    }

    /// Controls the color for the caret
    public var caretColor: UIColor {
        get { caretView.caretColor }
        set { caretView.caretColor = newValue }
    }
    
    var _selectedTextBackgroundColor = UIColor.green
    /// The color used to render the selection
    public var selectedTextBackgroundColor: UIColor {
        get {
            return _selectedTextBackgroundColor
        }
        set {
            _selectedTextBackgroundColor = newValue
        }
    }

    var lineAscent: CGFloat = 0
    var lineDescent: CGFloat = 0
    var lineLeading: CGFloat = 0
    
    open func bufferActivated(source: Terminal) {
        updateScroller ()
    }
    
    open func send(source: Terminal, data: ArraySlice<UInt8>) {
        terminalDelegate?.send (source: self, data: data)
    }
    
    /**
     * Given the current set of columns and rows returns a frame that would host this control.
     */
    open func getOptimalFrameSize () -> CGRect
    {
        return CGRect (x: 0, y: 0, width: cellDimension.width * CGFloat(terminal.cols), height: cellDimension.height * CGFloat(terminal.rows))
    }
    
    func getImageScale () -> CGFloat {
        self.window?.contentScaleFactor ?? 1
    }
    
    func getEffectiveWidth (rect: CGRect) -> CGFloat
    {
        return rect.width
    }
    
    func updateDebugDisplay ()
    {
    }
    
    func scale (image: UIImage, size: CGSize) -> UIImage {
        UIGraphicsBeginImageContext(size)
        
        let srcRatio = image.size.height/image.size.width
        let scaledRatio = size.width/size.height
        
        let dstRect: CGRect
        
        if srcRatio < scaledRatio {
            let nw = (size.height * image.size.width) / image.size.height
            dstRect = CGRect (x: (size.width-nw)/2, y: 0, width: nw, height: size.height)
        } else {
            let nh = (size.width * image.size.height) / image.size.width
            dstRect = CGRect (x: 0, y: (size.height-nh)/2, width: size.width, height: nh)
        }
        image.draw (in: dstRect)
        
        let ret = UIGraphicsGetImageFromCurrentImageContext() ?? image
        UIGraphicsEndImageContext()
        return ret
    }
    
    func drawImageInStripe (image: TTImage, srcY: CGFloat, width: CGFloat, srcHeight: CGFloat, dstHeight: CGFloat, size: CGSize) -> TTImage? {
        let srcRect = CGRect(x: 0, y: CGFloat(srcY), width: image.size.width, height: srcHeight)
        guard let cropCG = image.cgImage?.cropping(to: srcRect) else {
            return nil
        }
        let uicrop = UIImage (cgImage: cropCG)
        
        let destRect = CGRect(x: 0, y: 0, width: width, height: dstHeight)
        
        UIGraphicsBeginImageContextWithOptions(size, false, 0.0)
        guard let ctx = UIGraphicsGetCurrentContext() else {
            return nil
        }
        ctx.translateBy(x: 0, y: dstHeight)
        ctx.scaleBy(x: 1, y: -1)

        uicrop.draw(in: destRect)
        
        let stripe = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return stripe
    }

    open func scrolled(source terminal: Terminal, yDisp: Int) {
        //XselectionView.notifyScrolled(source: terminal)
        updateScroller()
        terminalDelegate?.scrolled(source: self, position: scrollPosition)
    }
    
    open func linefeed(source: Terminal) {
        selection.selectNone()
    }
    
    func updateScroller ()
    {
        contentSize = CGSize (width: CGFloat (terminal.buffer.cols) * cellDimension.width,
                              height: CGFloat (terminal.buffer.lines.count) * cellDimension.height)
        // contentOffset = CGPoint (x: 0, y: CGFloat (terminal.buffer.lines.count-terminal.rows)*cellDimension.height)
        //Xscroller.doubleValue = scrollPosition
        //Xscroller.knobProportion = scrollThumbsize
    }
    
    var userScrolling = false

    func getCurrentGraphicsContext () -> CGContext?
    {
        UIGraphicsGetCurrentContext ()
    }

    func backingScaleFactor () -> CGFloat
    {
        UIScreen.main.scale
    }
    
    override public func draw (_ dirtyRect: CGRect) {
        guard let context = getCurrentGraphicsContext() else {
            return
        }

        // Without these two lines, on font changes, some junk is being displayed
        nativeBackgroundColor.set ()
        context.clear(dirtyRect)

        // drawTerminalContents and CoreText expect the AppKit coordinate system
        context.scaleBy (x: 1, y: -1)
        context.translateBy(x: 0, y: -frame.height)
        drawTerminalContents (dirtyRect: dirtyRect, context: context)
    }
    
    open override var frame: CGRect {
        get {
            return super.frame
        }
        set(newValue) {
            super.frame = newValue
            if cellDimension == nil {
                return
            }
            let newRows = Int (newValue.height / cellDimension.height)
            let newCols = Int (getEffectiveWidth (rect: newValue) / cellDimension.width)
            
            if newCols != terminal.cols || newRows != terminal.rows {
                terminal.resize (cols: newCols, rows: newRows)
                fullBufferUpdate (terminal: terminal)
            }
            
            accessibility.invalidate ()
            search.invalidate ()
            
            terminalDelegate?.sizeChanged (source: self, newCols: newCols, newRows: newRows)
            setNeedsDisplay (frame)
        }
    }
    
    // iOS Keyboard input
    
    // UITextInputTraits
    public var keyboardType: UIKeyboardType {
        get {
            .`default`
        }
    }
    
    public var keyboardAppearance: UIKeyboardAppearance = .`default`
    public var returnKeyType: UIReturnKeyType = .`default`
    
    // This is wrong, but I can not find another good one
    public var textContentType: UITextContentType! = .none
    
    public var isSecureTextEntry: Bool = false
    public var enablesReturnKeyAutomatically: Bool = false
    public var autocapitalizationType: UITextAutocapitalizationType  = .none
    public var autocorrectionType: UITextAutocorrectionType = .no
    public var spellCheckingType: UITextSpellCheckingType = .no
    public var smartQuotesType: UITextSmartQuotesType = .no
    public var smartDashesType: UITextSmartDashesType = .no
    public var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    
    public override var canBecomeFirstResponder: Bool {
        true
    }
    
    public var hasText: Bool {
        return true
    }

    open func insertText(_ text: String) {
        let sendData = applyTextToInput (text)
        
        if sendData == "" {
            return
        }
        if terminalAccessory?.controlModifier ?? false {
            self.send (applyControlToEventCharacters (sendData))
            terminalAccessory?.controlModifier = false
        } else {
            uitiLog ("Inseting originalText=\"\(text)\" sending=\"\(sendData)\"")
            self.send (txt: sendData)
        }
        
        queuePendingDisplay()
    }

    open func deleteBackward() {
        self.send ([0x7f])
        
        inputDelegate?.selectionWillChange(self)
        // after backward deletion, marked range is always cleared, and length of selected range is always zero
        let rangeToDelete = _markedTextRange ?? _selectedTextRange
        var rangeStartPosition = rangeToDelete._start
        var rangeStartIndex = rangeStartPosition
        if rangeToDelete.isEmpty {
            if rangeStartIndex == 0 {
                return
            }
            rangeStartIndex -= 1
            
            textInputStorage.remove(at: rangeStartIndex)
            
            rangeStartPosition = rangeStartIndex
        } else {
            textInputStorage.removeSubrange(rangeToDelete._start..<rangeToDelete._end)
        }
        
        _markedTextRange = nil
        _selectedTextRange = xTextRange(rangeStartPosition, rangeStartPosition)
        inputDelegate?.selectionDidChange(self)
    }

    enum SendData {
        case text(String)
        case bytes([UInt8])
    }
    
    var sentData: SendData?
    
    func sendData (data: SendData?)
    {
        switch sentData {
        case .bytes(let b):
            self.send (b)
        case .text(let txt):
            self.send (txt: txt)
        default:
            break
        }
    }
    
    open override func resignFirstResponder() -> Bool {
        let code = super.resignFirstResponder()
        
        if code {
            keyRepeat?.invalidate()
            keyRepeat = nil
            
            terminalAccessory?.cancelTimer()
        }
        return code
    }
    var keyRepeat: Timer?
    
    public override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard let key = presses.first?.key else { return }
        sentData = nil

        switch key.keyCode {
        case .keyboardCapsLock:
            break // ignored
        case .keyboardLeftAlt:
            break // ignored
        case .keyboardLeftControl:
            break // ignored
        case .keyboardLeftShift:
            break // ignored
        case .keyboardLockingCapsLock:
            break // ignored
        case .keyboardLockingNumLock:
            break // ignored
        case .keyboardLockingScrollLock:
            break // ignored
        case .keyboardRightAlt:
            break // ignored
        case .keyboardRightControl:
            break // ignored
        case .keyboardRightShift:
            break // ignored
        case .keyboardScrollLock:
            break // ignored
        case .keyboardUpArrow:
            sentData = .bytes (terminal.applicationCursor ? EscapeSequences.MoveUpApp : EscapeSequences.MoveUpNormal)
        case .keyboardDownArrow:
            sentData = .bytes (terminal.applicationCursor ? EscapeSequences.MoveDownApp : EscapeSequences.MoveDownNormal)
        case .keyboardLeftArrow:
            sentData = .bytes (terminal.applicationCursor ? EscapeSequences.MoveLeftApp : EscapeSequences.MoveLeftNormal)
        case .keyboardRightArrow:
            sentData = .bytes (terminal.applicationCursor ? EscapeSequences.MoveRightApp : EscapeSequences.MoveRightNormal)
        case .keyboardPageUp:
            if terminal.applicationCursor {
                sentData = .bytes (EscapeSequences.CmdPageUp)
            } else {
                pageUp()
            }

        case .keyboardPageDown:
            if terminal.applicationCursor {
                sentData = .bytes (EscapeSequences.CmdPageDown)
            } else {
                pageDown()
            }
        case .keyboardHome:
            sentData = .bytes (terminal.applicationCursor ? EscapeSequences.MoveHomeApp : EscapeSequences.MoveHomeNormal)
            
        case .keyboardEnd:
            sentData = .bytes (terminal.applicationCursor ? EscapeSequences.MoveEndApp : EscapeSequences.MoveEndNormal)
        case .keyboardDeleteForward:
            sentData = .bytes (EscapeSequences.CmdDelKey)
            
        case .keyboardDeleteOrBackspace:
            sentData = .bytes ([backspaceSendsControlH ? 8 : 0x7f])
            
        case .keyboardEscape:
            sentData = .bytes ([0x1b])
            
        case .keyboardInsert:
            print (".keyboardInsert ignored")
            break
            
        case .keyboardReturn:
            sentData = .bytes ([10])
            
        case .keyboardTab:
            sentData = .bytes ([9])

        case .keyboardF1:
            sentData = .bytes (EscapeSequences.CmdF [1])
        case .keyboardF2:
            sentData = .bytes (EscapeSequences.CmdF [2])
        case .keyboardF3:
            sentData = .bytes (EscapeSequences.CmdF [3])
        case .keyboardF4:
            sentData = .bytes (EscapeSequences.CmdF [4])
        case .keyboardF5:
            sentData = .bytes (EscapeSequences.CmdF [5])
        case .keyboardF6:
            sentData = .bytes (EscapeSequences.CmdF [6])
        case .keyboardF7:
            sentData = .bytes (EscapeSequences.CmdF [7])
        case .keyboardF8:
            sentData = .bytes (EscapeSequences.CmdF [8])
        case .keyboardF9:
            sentData = .bytes (EscapeSequences.CmdF [9])
        case .keyboardF10:
            sentData = .bytes (EscapeSequences.CmdF [10])
        case .keyboardF11:
            sentData = .bytes (EscapeSequences.CmdF [11])
        case .keyboardF12, .keyboardF13, .keyboardF14, .keyboardF15, .keyboardF16,
             .keyboardF17, .keyboardF18, .keyboardF19, .keyboardF20, .keyboardF21,
             .keyboardF22, .keyboardF23, .keyboardF24:
            break
        case .keyboardPause, .keyboardStop, .keyboardMute, .keyboardVolumeUp, .keyboardVolumeDown:
            break
            
        default:
            if key.modifierFlags.contains (.alternate) {
                sentData = .text("\u{1b}\(key.charactersIgnoringModifiers)")
            } else {
                sentData = .text (key.characters)
            }
        }
        
        sendData (data: sentData)

    }
    
    public override func pressesChanged(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        //print ("pressesChanged Here\n")
    }

    public override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // guard let key = presses.first?.key else { return }
    }
    
    var pendingSelectionChanged = false
}

extension TerminalView: TerminalDelegate {
    open func selectionChanged(source: Terminal) {
        if pendingSelectionChanged {
            return
        }
        pendingSelectionChanged = true
        DispatchQueue.main.async {
            self.pendingSelectionChanged = false
            
            self.inputDelegate?.selectionWillChange (self)
            self.updateSelectionInBuffer(terminal: source)
            self.inputDelegate?.selectionDidChange(self)
 
            self.setNeedsDisplay (self.bounds)
        }
    }

    open func isProcessTrusted(source: Terminal) -> Bool {
        true
    }
    
    open func mouseModeChanged(source: Terminal) {
        // iOS TODO
        //X
    }
    
    open func setTerminalTitle(source: Terminal, title: String) {
        DispatchQueue.main.async {
            self.terminalDelegate?.setTerminalTitle(source: self, title: title)
        }
    }
  
    open func sizeChanged(source: Terminal) {
        DispatchQueue.main.async {
            self.terminalDelegate?.sizeChanged(source: self, newCols: source.cols, newRows: source.rows)
            self.updateScroller()
        }
    }
  
    open func setTerminalIconTitle(source: Terminal, title: String) {
        //
    }
  
    // Terminal.Delegate method implementation
    open func windowCommand(source: Terminal, command: Terminal.WindowManipulationCommand) -> [UInt8]? {
        return nil
    }
}

// Default implementations for TerminalViewDelegate

extension TerminalViewDelegate {
    public func requestOpenLink (source: TerminalView, link: String, params: [String:String])
    {
        if let fixedup = link.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            if let url = NSURLComponents(string: fixedup) {
                if let nested = url.url {
                    UIApplication.shared.open (nested)
                }
            }
        }
    }
    
    public func bell (source: TerminalView)
    {
        #if os(iOS)
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.warning)
        #endif
    }
}

extension UIColor {
    func getTerminalColor () -> Color {
        var red: CGFloat = 0.0, green: CGFloat = 0.0, blue: CGFloat = 0.0, alpha: CGFloat = 1.0
        self.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return Color(red: UInt16 (red*65535), green: UInt16(green*65535), blue: UInt16(blue*65535))
    }

    func inverseColor() -> UIColor {
        var red: CGFloat = 0.0, green: CGFloat = 0.0, blue: CGFloat = 0.0, alpha: CGFloat = 1.0
        self.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return UIColor (red: 1.0 - red, green: 1.0 - green, blue: 1.0 - blue, alpha: alpha)
    }

    static func make (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) -> TTColor
    {
        
        return UIColor(red: red,
                       green: green,
                       blue: blue,
                       alpha: 1.0)
    }
  
    static func make (hue: CGFloat, saturation: CGFloat, brightness: CGFloat, alpha: CGFloat) -> TTColor
    {
        return UIColor(hue: hue,
                       saturation: saturation,
                       brightness: brightness,
                       alpha: alpha)
    }
    
    static func make (color: Color) -> UIColor
    {
        UIColor (red: CGFloat (color.red) / 65535.0,
                 green: CGFloat (color.green) / 65535.0,
                 blue: CGFloat (color.blue) / 65535.0,
                 alpha: 1.0)
    }
    
    static func transparent () -> UIColor {
        return UIColor.clear
    }
}

extension UIImage {
    public convenience init (cgImage: CGImage, size: CGSize) {
        self.init (cgImage: cgImage, scale: -1, orientation: .up)
        //self.init (cgImage: cgImage)
    }
}

extension NSAttributedString {
    func fuzzyHasSelectionBackground () -> Bool
    {
        return true
    }
}
#endif
