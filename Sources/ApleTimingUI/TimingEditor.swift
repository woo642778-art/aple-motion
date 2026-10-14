#if canImport(UIKit)
import UIKit
import ApleTimingCore

@MainActor public final class TimingEditorViewController: UIViewController, UITextFieldDelegate, UIAdaptivePresentationControllerDelegate {
    public var onCommit: ((LayerTimingSnapshot) -> Void)?
    private let host: any TimingHostAdapter
    private let original: LayerTimingSnapshot
    private var history: DocumentHistory
    private var draft: TimingDocument
    private var selected = 0
    private var pendingPreview: DispatchWorkItem?
    private var committing = false
    private var closed = false
    private var invalidInput = false
    private let graph = TimingGraphView()
    private let content = UIStackView()
    private let status = UILabel()
    private let selectionLabel = UILabel()
    private let applyButton = UIButton(type: .system)
    private let undoButton = UIButton(type: .system)
    private let redoButton = UIButton(type: .system)
    private let graphMode = UISegmentedControl(items: ["Value", "Velocity"])
    private let inMode = UISegmentedControl(items: ["Linear", "Bezier", "Hold"])
    private let outMode = UISegmentedControl(items: ["Linear", "Bezier", "Hold"])
    private let automatic = UISwitch()
    private var fields: [String:UITextField] = [:]
    private var displayed: [String:String] = [:]
    private var graphHeight: NSLayoutConstraint!

    public init(host: any TimingHostAdapter) throws {
        let snapshot = try host.snapshot()
        self.host = host; self.original = snapshot; self.draft = snapshot.document
        self.history = try DocumentHistory(initial: snapshot.document)
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use init(host:)") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let cancel = button("Cancel", action: #selector(cancelEdit))
        applyButton.setTitle("Apply", for: .normal)
        applyButton.addTarget(self, action: #selector(applyEdit), for: .touchUpInside)
        applyButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        let title = UILabel(); title.text = original.title; title.font = .preferredFont(forTextStyle: .headline)
        title.adjustsFontForContentSizeCategory = true; title.numberOfLines = 2; title.textAlignment = .center
        let bar = UIStackView(arrangedSubviews: [cancel, title, applyButton])
        bar.axis = .horizontal; bar.spacing = 12; bar.alignment = .center
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        cancel.setContentHuggingPriority(.required, for: .horizontal)
        applyButton.setContentHuggingPriority(.required, for: .horizontal)
        bar.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(bar)
        let scroll = UIScrollView(); scroll.keyboardDismissMode = .interactive
        scroll.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(scroll)
        content.axis = .vertical; content.spacing = 12; content.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(content)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            bar.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            bar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -16),
            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 8),
            content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            content.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -32)
        ])
        if draft.mode == .speedRamp {
            graphMode.setTitle("Speed (x)", forSegmentAt: 0)
            graphMode.setTitle("Source time", forSegmentAt: 1)
        }
        graphMode.selectedSegmentIndex = 0
        graphMode.addTarget(self, action: #selector(graphModeChanged), for: .valueChanged)
        graphMode.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        content.addArrangedSubview(graphMode)
        graph.layer.cornerRadius = 12; graph.clipsToBounds = true
        graphHeight = graph.heightAnchor.constraint(equalToConstant: 240); graphHeight.isActive = true
        content.addArrangedSubview(graph)
        graph.onSelect = { [weak self] index in self?.select(index) }
        graph.onDrag = { [weak self] index, time, value in
            guard let self, !self.committing else { return }
            var next = self.draft; next.keys[index].time = time; next.keys[index].value = value
            self.accept(next, checkpoint: false)
        }
        graph.onDragEnd = { [weak self] cancelled in
            guard let self else { return }
            if cancelled { self.draft = self.history.current; self.refresh(); self.queuePreview() }
            else { do { try self.history.commit(self.draft); self.refresh() } catch { self.show(error) } }
        }
        undoButton.setTitle("Undo", for: .normal); redoButton.setTitle("Redo", for: .normal)
        undoButton.addTarget(self, action: #selector(undoEdit), for: .touchUpInside)
        redoButton.addTarget(self, action: #selector(redoEdit), for: .touchUpInside)
        content.addArrangedSubview(row([undoButton, redoButton, button("Add key", action: #selector(addKey)), button("Delete", action: #selector(deleteKey))]))
        selectionLabel.font = .preferredFont(forTextStyle: .body); selectionLabel.textAlignment = .center
        content.addArrangedSubview(row([button("Previous", action: #selector(previousKey)), selectionLabel, button("Next", action: #selector(nextKey))]))
        field("time", title: "Key time (seconds)")
        field("value", title: draft.mode == .speedRamp ? "Playback speed (x; negative reverses)" : "Property value")
        if draft.mode == .speedRamp { field("origin", title: "Source origin (seconds)") }
        inMode.addTarget(self, action: #selector(interpolationChanged), for: .valueChanged)
        outMode.addTarget(self, action: #selector(interpolationChanged), for: .valueChanged)
        labelled("Incoming interpolation", view: inMode)
        field("inSpeed", title: draft.mode == .speedRamp ? "Incoming speed slope (x/second)" : "Incoming velocity (units/second)")
        field("inInfluence", title: "Incoming influence (%)")
        labelled("Outgoing interpolation", view: outMode)
        field("outSpeed", title: draft.mode == .speedRamp ? "Outgoing speed slope (x/second)" : "Outgoing velocity (units/second)")
        field("outInfluence", title: "Outgoing influence (%)")
        automatic.addTarget(self, action: #selector(autoChanged), for: .valueChanged)
        labelled("Auto Bezier", view: automatic)
        content.addArrangedSubview(row([button("Easy Ease", action: #selector(easyEase)), button("Linear", action: #selector(linear)), button("Hold", action: #selector(hold))]))
        status.font = .preferredFont(forTextStyle: .footnote); status.adjustsFontForContentSizeCategory = true
        status.numberOfLines = 0; status.textColor = .secondaryLabel
        status.text = "Drag a key in the primary graph, or use numeric fields. Apply commits one edit to the host."
        content.addArrangedSubview(status)
        refresh()
    }
    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated); presentationController?.delegate = self
    }
    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        graphHeight.constant = view.bounds.width >= 650 ? 330 : (view.bounds.height < 500 ? 160 : 240)
    }
    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if !closed && !committing && (isBeingDismissed || isMovingFromParent || navigationController?.isBeingDismissed == true) {
            pendingPreview?.cancel(); host.cancelPreview(); closed = true
        }
    }
    public func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        if !closed { pendingPreview?.cancel(); host.cancelPreview(); closed = true }
    }
    private func button(_ title: String, action: Selector) -> UIButton {
        let b = UIButton(type: .system); b.setTitle(title, for: .normal)
        b.titleLabel?.font = .preferredFont(forTextStyle: .body)
        b.titleLabel?.adjustsFontForContentSizeCategory = true
        b.addTarget(self, action: action, for: .touchUpInside)
        b.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        return b
    }
    private func row(_ views: [UIView]) -> UIStackView {
        let r = UIStackView(arrangedSubviews: views); r.axis = .horizontal; r.distribution = .fillEqually; r.spacing = 8
        for v in views { v.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true }
        return r
    }
    private func labelled(_ title: String, view: UIView) {
        let label = UILabel(); label.text = title; label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true; label.numberOfLines = 0
        view.accessibilityLabel = title
        content.addArrangedSubview(label); content.addArrangedSubview(view)
        view.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
    }
    private func field(_ name: String, title: String) {
        let f = UITextField(); f.borderStyle = .roundedRect; f.keyboardType = .numbersAndPunctuation
        f.returnKeyType = .done; f.autocorrectionType = .no; f.spellCheckingType = .no
        f.font = .preferredFont(forTextStyle: .body); f.adjustsFontForContentSizeCategory = true
        f.accessibilityIdentifier = "aple.timing.\(name)"; f.delegate = self
        f.addTarget(self, action: #selector(fieldEnded(_:)), for: .editingDidEnd)
        fields[name] = f; labelled(title, view: f)
    }
    public func textFieldShouldReturn(_ textField: UITextField) -> Bool { textField.resignFirstResponder(); return true }
    @objc private func fieldEnded(_ field: UITextField) {
        guard !committing, let name = fields.first(where: { $0.value === field })?.key else { return }
        let text = (field.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text == displayed[name] { return }
        guard let value = Double(text), value.isFinite else { invalidInput = true; show(TimingError.invalidNumber); return }
        var next = draft
        do {
            switch name {
            case "time": next.keys[selected].time = try Tick(seconds: value)
            case "value": next.keys[selected].value = value
            case "origin": next.sourceOrigin = value
            case "inSpeed": next.keys[selected].inEase.speed = value; next.keys[selected].inInterpolation = .bezier; next.keys[selected].autoBezier = false
            case "outSpeed": next.keys[selected].outEase.speed = value; next.keys[selected].outInterpolation = .bezier; next.keys[selected].autoBezier = false
            case "inInfluence": next.keys[selected].inEase.influence = value/100; next.keys[selected].inInterpolation = .bezier; next.keys[selected].autoBezier = false
            case "outInfluence": next.keys[selected].outEase.influence = value/100; next.keys[selected].outInterpolation = .bezier; next.keys[selected].autoBezier = false
            default: return
            }
            try next.validate(); invalidInput = false; accept(next)
        } catch { invalidInput = true; show(error) }
    }
    private func accept(_ next: TimingDocument, checkpoint: Bool = true) {
        do {
            try next.validate()
            if checkpoint { try history.commit(next) }
            draft = next; selected = min(selected, draft.keys.count-1)
            refresh(); queuePreview()
        } catch { show(error) }
    }
    private func select(_ index: Int) {
        guard !committing else { return }; view.endEditing(true)
        guard !invalidInput, draft.keys.indices.contains(index) else { return }
        selected = index; refresh()
    }
    private func refresh() {
        guard isViewLoaded, draft.keys.indices.contains(selected) else { return }
        let key = draft.keys[selected]
        let curve = try? draft.curve()
        let incoming = curve?.sideEase(at: selected, outgoing: false) ?? key.inEase
        let outgoing = curve?.sideEase(at: selected, outgoing: true) ?? key.outEase
        let values = ["time":key.time.seconds, "value":key.value, "origin":draft.sourceOrigin,
                      "inSpeed":incoming.speed, "inInfluence":incoming.influence*100,
                      "outSpeed":outgoing.speed, "outInfluence":outgoing.influence*100]
        for (name, value) in values where fields[name]?.isFirstResponder != true {
            let text = String(format: "%.12g", value); fields[name]?.text = text; displayed[name] = text
        }
        inMode.selectedSegmentIndex = Interpolation.allCases.firstIndex(of: key.inInterpolation) ?? 0
        outMode.selectedSegmentIndex = Interpolation.allCases.firstIndex(of: key.outInterpolation) ?? 0
        automatic.isOn = key.autoBezier
        selectionLabel.text = "Key \(selected+1) / \(draft.keys.count)"
        undoButton.isEnabled = history.canUndo && !committing; redoButton.isEnabled = history.canRedo && !committing
        graph.configure(document: draft, selected: selected, secondary: graphMode.selectedSegmentIndex == 1)
    }
    private func queuePreview() {
        guard pendingPreview == nil, !committing, !closed else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }; self.pendingPreview = nil
            guard !self.committing, !self.closed else { return }
            do { try self.host.preview(self.draft) } catch { self.show(error) }
        }
        pendingPreview = work; DispatchQueue.main.asyncAfter(deadline: .now()+1.0/30, execute: work)
    }
    private func show(_ error: Error) { status.text = error.localizedDescription; status.textColor = .systemRed }
    @objc private func graphModeChanged() { refresh() }
    @objc private func previousKey() { select(max(0, selected-1)) }
    @objc private func nextKey() { select(min(draft.keys.count-1, selected+1)) }
    @objc private func undoEdit() { view.endEditing(true); if let d = history.undo() { draft = d; invalidInput = false; selected = min(selected,d.keys.count-1); refresh(); queuePreview() } }
    @objc private func redoEdit() { view.endEditing(true); if let d = history.redo() { draft = d; invalidInput = false; selected = min(selected,d.keys.count-1); refresh(); queuePreview() } }
    @objc private func interpolationChanged() {
        var d = draft; d.keys[selected].inInterpolation = Interpolation.allCases[inMode.selectedSegmentIndex]
        d.keys[selected].outInterpolation = Interpolation.allCases[outMode.selectedSegmentIndex]
        d.keys[selected].autoBezier = false; accept(d)
    }
    @objc private func autoChanged() {
        var d = draft; d.keys[selected].autoBezier = automatic.isOn
        if automatic.isOn { d.keys[selected].inInterpolation = .bezier; d.keys[selected].outInterpolation = .bezier }
        accept(d)
    }
    @objc private func easyEase() { preset(.bezier) }
    @objc private func linear() { preset(.linear) }
    @objc private func hold() { preset(.hold) }
    private func preset(_ mode: Interpolation) {
        var d = draft; d.keys[selected].inInterpolation = mode; d.keys[selected].outInterpolation = mode
        d.keys[selected].autoBezier = false
        if mode == .bezier { d.keys[selected].inEase = .easy; d.keys[selected].outEase = .easy }
        accept(d)
    }
    @objc private func addKey() {
        view.endEditing(true); guard !invalidInput else { return }
        guard draft.keys.count >= 2 else { show(TimingError.tooFewKeys); return }
        let i = min(selected, draft.keys.count-2)
        let a = draft.keys[i].time.rawValue, b = draft.keys[i+1].time.rawValue
        guard b-a > 1 else { show(TimingError.invalidTime); return }
        let time = Tick(rawValue: a+(b-a)/2)
        do {
            let value = try draft.curve().value(at: time)
            var d = draft; d.keys.insert(ScalarKeyframe(time: time, value: value), at: i+1)
            selected = i+1; accept(d)
        } catch { show(error) }
    }
    @objc private func deleteKey() {
        view.endEditing(true); guard !invalidInput else { return }
        if draft.mode == .speedRamp && (selected == 0 || selected == draft.keys.count-1) {
            status.text = "Speed-ramp endpoints define the output duration and cannot be deleted."; return
        }
        guard draft.keys.count > 1 else { show(TimingError.tooFewKeys); return }
        var d = draft; d.keys.remove(at: selected); selected = min(selected,d.keys.count-1); accept(d)
    }
    @objc private func cancelEdit() {
        guard !committing, !closed else { return }; pendingPreview?.cancel(); pendingPreview = nil
        host.cancelPreview(); closed = true; dismiss(animated: true)
    }
    @objc private func applyEdit() {
        view.endEditing(true); guard !invalidInput, !committing, !closed else { return }
        do { try draft.validate() } catch { show(error); return }
        pendingPreview?.cancel(); pendingPreview = nil
        committing = true; isModalInPresentation = true; content.isUserInteractionEnabled = false; applyButton.isEnabled = false
        let submitted = draft
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await self.host.commit(submitted, expectedRevision: self.original.revision)
                guard result.layerID == self.original.layerID else { throw TimingError.invalidDocument }
                self.closed = true; self.onCommit?(result); self.dismiss(animated: true)
            } catch {
                self.committing = false; self.isModalInPresentation = false
                self.content.isUserInteractionEnabled = true; self.applyButton.isEnabled = true; self.show(error)
            }
        }
    }
}

@MainActor private final class TimingGraphView: UIView {
    var onSelect: ((Int) -> Void)?
    var onDrag: ((Int, Tick, Double) -> Void)?
    var onDragEnd: ((Bool) -> Void)?
    private var document: TimingDocument?
    private var selected = 0
    private var secondary = false
    private var samples: [Double] = []
    private var minY = -1.0, maxY = 1.0
    private var activeDrag: Int?
    private var dragging = false
    private var plot: CGRect { bounds.inset(by: UIEdgeInsets(top: 20, left: 42, bottom: 28, right: 18)) }
    override init(frame: CGRect) {
        super.init(frame: frame); backgroundColor = .secondarySystemBackground
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.maximumNumberOfTouches = 1; addGestureRecognizer(pan)
        accessibilityLabel = "Timing graph. Numeric controls below provide accessible keyframe editing."
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use programmatic initialization") }
    func configure(document: TimingDocument, selected: Int, secondary: Bool) {
        self.document = document; self.selected = selected; self.secondary = secondary
        guard let curve = try? document.curve() else { return }
        let ramp = try? document.ramp()
        let first = document.keys[0].time.seconds, last = document.keys.last!.time.seconds
        samples = (0...256).map { i in
            guard let time = try? Tick(seconds: first+(last-first)*Double(i)/256) else { return 0 }
            if secondary { return document.mode == .speedRamp ? (ramp?.sourceTime(at: time) ?? 0) : curve.velocity(at: time) }
            return curve.value(at: time)
        }
        if !dragging {
            let lo = samples.min() ?? -1, hi = samples.max() ?? 1
            let padding = max(0.1, max(hi-lo, abs(hi)*0.1)*0.15)
            minY = lo-padding; maxY = hi+padding
        }
        setNeedsDisplay()
    }
    override func draw(_ rect: CGRect) {
        guard let d = document, plot.width > 0, plot.height > 0, let ctx = UIGraphicsGetCurrentContext() else { return }
        let area = plot
        ctx.setStrokeColor(UIColor.separator.cgColor); ctx.setLineWidth(0.5)
        for i in 0...4 {
            let y = area.minY+area.height*CGFloat(i)/4; ctx.move(to: CGPoint(x:area.minX,y:y)); ctx.addLine(to: CGPoint(x:area.maxX,y:y))
            let x = area.minX+area.width*CGFloat(i)/4; ctx.move(to: CGPoint(x:x,y:area.minY)); ctx.addLine(to: CGPoint(x:x,y:area.maxY))
        }
        ctx.strokePath(); ctx.saveGState(); ctx.clip(to: area)
        let path = UIBezierPath()
        for (i,value) in samples.enumerated() {
            let p = CGPoint(x:area.minX+area.width*CGFloat(i)/CGFloat(max(1,samples.count-1)), y:yPosition(value))
            if i == 0 { path.move(to:p) } else { path.addLine(to:p) }
        }
        UIColor.systemTeal.setStroke(); path.lineWidth = 2; path.stroke(); ctx.restoreGState()
        if !secondary {
            for i in d.keys.indices {
                let p = point(d.keys[i]); let radius:CGFloat = i == selected ? 7 : 5
                (i == selected ? UIColor.systemOrange : UIColor.label).setFill()
                UIBezierPath(ovalIn:CGRect(x:p.x-radius,y:p.y-radius,width:radius*2,height:radius*2)).fill()
            }
        }
        let attributes: [NSAttributedString.Key:Any] = [.font:UIFont.monospacedDigitSystemFont(ofSize:11,weight:.regular), .foregroundColor:UIColor.secondaryLabel]
        (String(format:"%.3g",maxY) as NSString).draw(at:CGPoint(x:2,y:area.minY),withAttributes:attributes)
        (String(format:"%.3g",minY) as NSString).draw(at:CGPoint(x:2,y:area.maxY-12),withAttributes:attributes)
        (String(format:"%.3g s",d.keys[0].time.seconds) as NSString).draw(at:CGPoint(x:area.minX,y:area.maxY+7),withAttributes:attributes)
        (String(format:"%.3g s",d.keys.last!.time.seconds) as NSString).draw(at:CGPoint(x:area.maxX-65,y:area.maxY+7),withAttributes:attributes)
    }
    private func yPosition(_ value: Double) -> CGFloat { plot.maxY-CGFloat((value-minY)/(maxY-minY))*plot.height }
    private func point(_ key: ScalarKeyframe) -> CGPoint {
        guard let d = document else { return .zero }
        let first = d.keys[0].time.seconds, span = d.keys.last!.time.seconds-first
        return CGPoint(x:plot.minX+CGFloat(span > 0 ? (key.time.seconds-first)/span : 0.5)*plot.width, y:yPosition(key.value))
    }
    private func nearest(_ position: CGPoint) -> Int? {
        guard let d = document, !secondary else { return nil }
        let index = d.keys.indices.min { a,b in
            let pa = point(d.keys[a]), pb = point(d.keys[b])
            return hypot(pa.x-position.x,pa.y-position.y) < hypot(pb.x-position.x,pb.y-position.y)
        }
        guard let index else { return nil }; let p = point(d.keys[index])
        return hypot(p.x-position.x,p.y-position.y) <= 30 ? index : nil
    }
    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        if let index = nearest(gesture.location(in:self)) { onSelect?(index) }
    }
    @objc private func panned(_ gesture: UIPanGestureRecognizer) {
        guard !secondary, let d = document, plot.width > 0, plot.height > 0 else { return }
        let location = gesture.location(in:self)
        switch gesture.state {
        case .began:
            activeDrag = nearest(location); dragging = activeDrag != nil
            if let index = activeDrag { onSelect?(index) }
        case .changed:
            guard let index = activeDrag else { return }
            let fraction = min(1,max(0,Double((location.x-plot.minX)/plot.width)))
            var time = d.keys[index].time
            if index > 0 && index < d.keys.count-1 {
                let seconds = d.keys[0].time.seconds+(d.keys.last!.time.seconds-d.keys[0].time.seconds)*fraction
                guard let candidate = try? Tick(seconds:seconds) else { return }
                time = Tick(rawValue:min(d.keys[index+1].time.rawValue-1,max(d.keys[index-1].time.rawValue+1,candidate.rawValue)))
            }
            let value = maxY-Double((location.y-plot.minY)/plot.height)*(maxY-minY)
            onDrag?(index,time,value)
        case .ended, .cancelled, .failed:
            if dragging { dragging = false; activeDrag = nil; onDragEnd?(gesture.state != .ended) }
        default: break
        }
    }
}
#endif
