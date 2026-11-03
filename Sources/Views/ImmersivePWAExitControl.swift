//
//  ImmersivePWAExitControl.swift
//  WebBridgeKit
//

import UIKit

/// Host-owned bottom sheet for infrequent immersive actions.
final class ImmersiveFunctionSheet: UIView {
    struct Item {
        let title: String
        let subtitle: String
        let symbol: LucideIcon
        let action: () -> Void
    }

    private let dimmer = UIControl()
    private let panel = UIView()
    private var items: [Item] = []

    static func show(in host: UIView, items: [Item]) {
        guard !items.isEmpty else { return }
        // A sheet can outlive a failed dismissal when the browser hierarchy is
        // replaced during a blank/error-page transition. Never let that stale
        // view swallow the next More tap.
        host.subviews.compactMap { $0 as? ImmersiveFunctionSheet }
            .forEach { $0.removeFromSuperview() }
        let sheet = ImmersiveFunctionSheet(frame: host.bounds)
        sheet.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        sheet.items = items
        sheet.configure()
        host.addSubview(sheet)
        sheet.layoutIfNeeded()
        sheet.panel.transform = CGAffineTransform(translationX: 0, y: sheet.panel.bounds.height)
        sheet.dimmer.alpha = 0
        UIView.animate(withDuration: 0.3, delay: 0, options: [.curveEaseOut]) {
            sheet.dimmer.alpha = 1
            sheet.panel.transform = .identity
        }
        UIAccessibility.post(notification: .screenChanged, argument: sheet.panel)
    }

    private func configure() {
        accessibilityIdentifier = "immersive.functionSheet"
        accessibilityViewIsModal = true
        dimmer.backgroundColor = ThemeTokens.Color.overlay
        dimmer.isAccessibilityElement = true
        dimmer.accessibilityTraits = .button
        dimmer.accessibilityLabel = "关闭功能菜单"
        dimmer.addTarget(self, action: #selector(close), for: .touchUpInside)
        addSubview(dimmer)
        dimmer.translatesAutoresizingMaskIntoConstraints = false
        panel.backgroundColor = ThemeTokens.Color.background
        panel.layer.cornerRadius = 26
        panel.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        panel.clipsToBounds = true
        addSubview(panel)
        panel.translatesAutoresizingMaskIntoConstraints = false

        let handle = UIView()
        handle.backgroundColor = ThemeTokens.Color.textTertiary
        handle.layer.cornerRadius = 2.5
        handle.translatesAutoresizingMaskIntoConstraints = false
        let title = UILabel()
        title.text = "应用功能"
        title.textColor = ThemeTokens.Color.text
        title.font = .preferredFont(forTextStyle: .headline)
        title.adjustsFontForContentSizeCategory = true
        title.textAlignment = .center
        let rows = UIStackView()
        rows.axis = .vertical
        rows.backgroundColor = ThemeTokens.Color.surface
        rows.layer.cornerRadius = 16
        rows.clipsToBounds = true
        for (index, item) in items.enumerated() {
            let row = makeRow(item, index: index)
            rows.addArrangedSubview(row)
        }
        let scroll = UIScrollView()
        scroll.showsVerticalScrollIndicator = true
        scroll.addSubview(rows)
        rows.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            rows.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            rows.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            rows.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            scroll.heightAnchor.constraint(equalToConstant: min(CGFloat(items.count) * 68, 340))
        ])
        let content = UIStackView(arrangedSubviews: [handle, title, scroll])
        content.axis = .vertical
        content.alignment = .fill
        content.spacing = 16
        content.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(content)
        NSLayoutConstraint.activate([
            dimmer.leadingAnchor.constraint(equalTo: leadingAnchor), dimmer.trailingAnchor.constraint(equalTo: trailingAnchor),
            dimmer.topAnchor.constraint(equalTo: topAnchor), dimmer.bottomAnchor.constraint(equalTo: bottomAnchor),
            panel.centerXAnchor.constraint(equalTo: centerXAnchor), panel.bottomAnchor.constraint(equalTo: bottomAnchor),
            panel.widthAnchor.constraint(equalTo: widthAnchor),
            content.topAnchor.constraint(equalTo: panel.topAnchor, constant: 10),
            content.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -20),
            content.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -20),
            handle.heightAnchor.constraint(equalToConstant: 5),
            handle.widthAnchor.constraint(equalToConstant: 40)
        ])
        content.alignment = .center
        title.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        scroll.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        panel.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(pan(_:))))
    }

    private func makeRow(_ item: Item, index: Int) -> UIView {
        let button = UIButton(type: .custom)
        button.tag = index
        button.accessibilityLabel = item.title
        button.addTarget(self, action: #selector(selectItem(_:)), for: .touchUpInside)
        let iconBox = UIView()
        iconBox.backgroundColor = ThemeTokens.Color.primarySoft
        iconBox.layer.cornerRadius = 12
        let icon = UIImageView(image: item.symbol.image())
        icon.tintColor = ThemeTokens.Color.primary
        icon.contentMode = .scaleAspectFit
        icon.translatesAutoresizingMaskIntoConstraints = false
        iconBox.addSubview(icon)
        let name = UILabel()
        name.text = item.title
        name.textColor = ThemeTokens.Color.text
        name.font = .preferredFont(forTextStyle: .body)
        name.adjustsFontForContentSizeCategory = true
        let detail = UILabel()
        detail.text = item.subtitle
        detail.textColor = ThemeTokens.Color.textSecondary
        detail.font = .preferredFont(forTextStyle: .caption1)
        detail.adjustsFontForContentSizeCategory = true
        let labels = UIStackView(arrangedSubviews: [name, detail])
        labels.axis = .vertical
        labels.spacing = 3
        let chevron = UIImageView(image: LucideIcon.chevronRight.image())
        chevron.tintColor = ThemeTokens.Color.textTertiary
        chevron.contentMode = .scaleAspectFit
        let row = UIStackView(arrangedSubviews: [iconBox, labels, chevron])
        row.alignment = .center
        row.spacing = 14
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -16),
            row.topAnchor.constraint(equalTo: button.topAnchor, constant: 12),
            row.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: -12),
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 68),
            iconBox.widthAnchor.constraint(equalToConstant: 44), iconBox.heightAnchor.constraint(equalToConstant: 44),
            icon.centerXAnchor.constraint(equalTo: iconBox.centerXAnchor), icon.centerYAnchor.constraint(equalTo: iconBox.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 21), icon.heightAnchor.constraint(equalToConstant: 21),
            chevron.widthAnchor.constraint(equalToConstant: 12)
        ])
        return button
    }

    @objc private func selectItem(_ sender: UIButton) {
        guard items.indices.contains(sender.tag) else { return }
        let action = items[sender.tag].action
        dismiss(completion: action)
    }

    @objc private func close() { dismiss() }

    @objc private func pan(_ gesture: UIPanGestureRecognizer) {
        let distance = max(0, gesture.translation(in: self).y)
        if gesture.state == .changed { panel.transform = CGAffineTransform(translationX: 0, y: distance) }
        if gesture.state == .ended || gesture.state == .cancelled {
            if distance > 80 || gesture.velocity(in: self).y > 700 {
                dismiss()
            } else {
                UIView.animate(withDuration: 0.2) { self.panel.transform = .identity }
            }
        }
    }

    private func dismiss(completion: (() -> Void)? = nil) {
        UIView.animate(withDuration: 0.22, animations: {
            self.dimmer.alpha = 0
            self.panel.transform = CGAffineTransform(translationX: 0, y: self.panel.bounds.height)
        }, completion: { _ in
            self.removeFromSuperview()
            completion?()
        })
    }

    override func accessibilityPerformEscape() -> Bool { dismiss(); return true }
}

/// A movable host-owned exit affordance for immersive HTML applications.
public final class ImmersivePWAExitControl: UIControl {

    private enum Edge: Int {
        case left
        case right
    }

    private enum Presentation {
        case collapsed
        case expanded
    }

    /// Dedicated close action; the edge-side collapse arrow never calls it.
    public var onExit: (() -> Void)?
    /// Recovery is deliberately placed inside the expanded return capsule so
    /// immersive pages stay visually quiet until the user asks for controls.
    public var onRefresh: (() -> Void)?
    /// Expanded 收藏格：与两壳工具栏星标写入同一收藏表；点击只切换，不收起。
    public var onFavorite: (() -> Void)?
    /// 二级功能入口：权限、书签等低频操作收进这里，避免常驻右上角胶囊。
    public var onMore: (() -> Void)?
    /// 当前页面收藏态；由宿主在导航或切换后刷新，展开态实时反映。
    public var isFavorited: Bool = false {
        didSet {
            guard presentation == .expanded else { return }
            updateArrow()
        }
    }

    private let size: CGFloat = 44
    private let expandedWidth: CGFloat = 236
    /// Collapsed controls keep only 20pt on screen. With the 44pt control
    /// width, that is one third less protrusion than the former 30pt sliver.
    static let collapsedVisibleWidth: CGFloat = 20
    /// Extends the tap target beyond the clipped visible sliver so a tap on
    /// the edge still registers instead of falling through to the PWA.
    private let hitAreaPadding: CGFloat = 20
    private let positionStore = UserDefaults.standard
    private let edgeKey = "com.webbridgekit.immersive-exit.edge"
    private let verticalRatioKey = "com.webbridgekit.immersive-exit.vertical-ratio"
    private let arrowImageView = UIImageView()
    private let closeImageView = UIImageView()
    private let refreshImageView = UIImageView()
    private let favoriteImageView = UIImageView()
    private let moreImageView = UIImageView()
    private let actionDivider = UIView()
    private let favoriteDivider = UIView()
    private let closeDivider = UIView()
    private let moreDivider = UIView()
    private lazy var panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
    private lazy var tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))

    private var edge: Edge = .left
    private var presentation: Presentation = .collapsed
    private var dragStartCenter: CGPoint = .zero
    private var isDragging = false

    public override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let hitArea = bounds.insetBy(dx: -hitAreaPadding, dy: -hitAreaPadding)
        return hitArea.contains(point)
    }

    public override init(frame: CGRect) {
        super.init(frame: frame)
        restorePosition()
        setupAppearance()
        tapGesture.delegate = self
        addGestureRecognizer(tapGesture)
        panGesture.delegate = self
        addGestureRecognizer(panGesture)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Repositions the control after safe-area or rotation changes.
    public func updateLayout(in hostView: UIView, animated: Bool = false) {
        let applyFrame = { [weak self, weak hostView] in
            guard let self, let hostView else { return }
            self.frame = self.frame(in: hostView)
            self.updateArrow()
        }

        if animated {
            UIView.animate(withDuration: 0.2, animations: applyFrame)
        } else {
            applyFrame()
        }
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard let superview else { return }

        switch presentation {
        case .collapsed:
            presentation = .expanded
            updateLayout(in: superview, animated: true)
        case .expanded:
            let location = gesture.location(in: self)
            if favoriteHitFrame.contains(location) {
                onFavorite?()
            } else if refreshHitFrame.contains(location) {
                onRefresh?()
                presentation = .collapsed
                updateLayout(in: superview, animated: true)
            } else if closeHitFrame.contains(location) {
                onExit?()
            } else if moreHitFrame.contains(location) {
                presentation = .collapsed
                updateLayout(in: superview, animated: true)
                onMore?()
            } else {
                // The edge-side arrow only collapses the control; exiting
                // lives in the dedicated close cell so accidental exits are
                // no longer triggered by the collapse affordance.
                presentation = .collapsed
                updateLayout(in: superview, animated: true)
            }
        }
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let superview else { return }

        switch gesture.state {
        case .began:
            isDragging = false
            presentation = .expanded
            dragStartCenter = center
        case .changed:
            let translation = gesture.translation(in: superview)
            isDragging = isDragging || abs(translation.x) > 3 || abs(translation.y) > 3
            guard isDragging else { return }

            let bounds = draggableBounds(in: superview)
            center = CGPoint(
                x: min(max(dragStartCenter.x + translation.x, bounds.minX), bounds.maxX),
                y: min(max(dragStartCenter.y + translation.y, bounds.minY), bounds.maxY)
            )
        case .ended, .cancelled, .failed:
            guard isDragging else { return }
            edge = center.x < superview.bounds.midX ? .left : .right
            saveVerticalPosition(in: superview)
            presentation = .collapsed
            updateLayout(in: superview, animated: true)
            DispatchQueue.main.async { [weak self] in self?.isDragging = false }
        default:
            break
        }
    }

    private func setupAppearance() {
        backgroundColor = ThemeTokens.Color.surface
        layer.cornerRadius = size / 2
        layer.borderWidth = 1
        layer.borderColor = ThemeTokens.Color.border.cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.14
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 3)
        accessibilityIdentifier = "browserManager.immersiveReturnButton"
        addSubview(arrowImageView)
        addSubview(closeImageView)
        addSubview(refreshImageView)
        addSubview(favoriteImageView)
        addSubview(moreImageView)
        actionDivider.backgroundColor = ThemeTokens.Color.border
        addSubview(actionDivider)
        favoriteDivider.backgroundColor = ThemeTokens.Color.border
        addSubview(favoriteDivider)
        closeDivider.backgroundColor = ThemeTokens.Color.border
        addSubview(closeDivider)
        moreDivider.backgroundColor = ThemeTokens.Color.border
        addSubview(moreDivider)
        updateArrow()
    }

    private func updateArrow() {
        let image: UIImage?
        let closeImage: UIImage?
        let x: CGFloat
        let closeX: CGFloat

        switch presentation {
        case .expanded:
            image = (edge == .left ? LucideIcon.chevronLeft : LucideIcon.chevronRight)
                .templateImage(pointSize: 18, weight: .semibold)
            x = collapseHitFrame.insetBy(dx: 13, dy: 13).minX
            closeImage = LucideIcon.xmark.templateImage(pointSize: 18, weight: .semibold)
            closeX = closeHitFrame.insetBy(dx: 13, dy: 13).minX
            refreshImageView.image = LucideIcon.refresh.templateImage(pointSize: 18, weight: .semibold)
            refreshImageView.tintColor = ThemeTokens.Color.text
            refreshImageView.frame = refreshHitFrame.insetBy(dx: 13, dy: 13)
            refreshImageView.isHidden = false
            favoriteImageView.image = LucideIcon.star.templateImage(pointSize: 18, weight: .semibold)
            favoriteImageView.tintColor = isFavorited ? ThemeTokens.Color.warning : ThemeTokens.Color.text
            favoriteImageView.frame = favoriteHitFrame.insetBy(dx: 13, dy: 13)
            favoriteImageView.isHidden = false
            moreImageView.image = LucideIcon.ellipsis.templateImage(pointSize: 18, weight: .semibold)
            moreImageView.tintColor = ThemeTokens.Color.text
            moreImageView.frame = moreHitFrame.insetBy(dx: 13, dy: 13)
            moreImageView.isHidden = false
            closeDivider.frame = CGRect(x: edge == .left ? 139.5 : 92.5, y: 10, width: 1, height: size - 20)
            closeDivider.isHidden = false
            actionDivider.frame = CGRect(x: edge == .left ? 43.5 : 140.5, y: 10, width: 1, height: size - 20)
            actionDivider.isHidden = false
            favoriteDivider.frame = CGRect(x: edge == .left ? 91.5 : 44.5, y: 10, width: 1, height: size - 20)
            favoriteDivider.isHidden = false
            moreDivider.frame = CGRect(x: edge == .left ? 187.5 : 188.5, y: 10, width: 1, height: size - 20)
            moreDivider.isHidden = false
            accessibilityLabel = "收起、关闭、刷新、收藏网页或打开更多功能"
        case .collapsed:
            image = (edge == .left ? LucideIcon.chevronRight : LucideIcon.chevronLeft)
                .templateImage(pointSize: 18, weight: .semibold)
            let visibleArrowInset = max(0, (Self.collapsedVisibleWidth - 18) / 2)
            x = edge == .left
                ? size - Self.collapsedVisibleWidth + visibleArrowInset
                : visibleArrowInset
            closeImage = nil
            closeX = 0
            refreshImageView.isHidden = true
            favoriteImageView.isHidden = true
            moreImageView.isHidden = true
            actionDivider.isHidden = true
            favoriteDivider.isHidden = true
            closeDivider.isHidden = true
            moreDivider.isHidden = true
            accessibilityLabel = "显示浏览器控制条"
        }

        arrowImageView.image = image
        arrowImageView.tintColor = ThemeTokens.Color.text
        arrowImageView.frame = CGRect(x: x, y: 13, width: 18, height: 18)
        closeImageView.image = closeImage
        closeImageView.tintColor = ThemeTokens.Color.text
        closeImageView.frame = CGRect(x: closeX, y: 13, width: 18, height: 18)
    }

    private func frame(in hostView: UIView) -> CGRect {
        let safeArea = hostView.safeAreaInsets
        let minY = safeArea.top + 10
        let maxY = max(minY, hostView.bounds.height - safeArea.bottom - size - 10)
        let ratio = min(max(positionStore.double(forKey: verticalRatioKey), 0), 1)
        let y = minY + (maxY - minY) * ratio

        let x: CGFloat
        let width: CGFloat
        switch presentation {
        case .expanded:
            width = expandedWidth
            x = edge == .left
                ? safeArea.left + 12
                : hostView.bounds.width - safeArea.right - expandedWidth - 12
        case .collapsed:
            width = size
            x = edge == .left
                ? safeArea.left - (size - Self.collapsedVisibleWidth)
                : hostView.bounds.width - safeArea.right - Self.collapsedVisibleWidth
        }

        return CGRect(x: x, y: y, width: width, height: size)
    }

    /// 展开态五格：左缘 [收起 0-44 | 关闭 48-92 | 刷新 96-140 | 收藏 144-188 | 更多 192-236]，右缘镜像。
    private var collapseHitFrame: CGRect {
        switch edge {
        case .left:
            return CGRect(x: 0, y: 0, width: size, height: size)
        case .right:
            return CGRect(x: expandedWidth - size, y: 0, width: size, height: size)
        }
    }

    private var closeHitFrame: CGRect {
        switch edge {
        case .left:
            return CGRect(x: size + 4, y: 0, width: size, height: size)
        case .right:
            return CGRect(x: 2 * size + 8, y: 0, width: size, height: size)
        }
    }

    private var refreshHitFrame: CGRect {
        switch edge {
        case .left:
            return CGRect(x: 2 * size + 4, y: 0, width: size, height: size)
        case .right:
            return CGRect(x: size + 4, y: 0, width: size, height: size)
        }
    }

    private var favoriteHitFrame: CGRect {
        switch edge {
        case .left:
            return CGRect(x: 3 * size + 8, y: 0, width: size, height: size)
        case .right:
            return CGRect(x: 0, y: 0, width: size, height: size)
        }
    }

    private var moreHitFrame: CGRect {
        switch edge {
        case .left:
            return CGRect(x: 4 * size + 12, y: 0, width: size, height: size)
        case .right:
            return CGRect(x: expandedWidth - 2 * size, y: 0, width: size, height: size)
        }
    }

    private func draggableBounds(in hostView: UIView) -> CGRect {
        let safeArea = hostView.safeAreaInsets
        return CGRect(
            x: safeArea.left + size / 2,
            y: safeArea.top + size / 2 + 10,
            width: max(0, hostView.bounds.width - safeArea.left - safeArea.right - size),
            height: max(0, hostView.bounds.height - safeArea.top - safeArea.bottom - size - 20)
        )
    }

    private func restorePosition() {
        edge = Edge(rawValue: positionStore.integer(forKey: edgeKey)) ?? .left
        if positionStore.object(forKey: verticalRatioKey) == nil {
            positionStore.set(0.1, forKey: verticalRatioKey)
        }
    }

    private func saveVerticalPosition(in hostView: UIView) {
        let safeArea = hostView.safeAreaInsets
        let minY = safeArea.top + 10
        let maxY = max(minY, hostView.bounds.height - safeArea.bottom - size - 10)
        let ratio = maxY == minY ? 0 : (frame.minY - minY) / (maxY - minY)
        positionStore.set(edge.rawValue, forKey: edgeKey)
        positionStore.set(min(max(ratio, 0), 1), forKey: verticalRatioKey)
    }
}

extension ImmersivePWAExitControl: UIGestureRecognizerDelegate {
    /// The pan gesture must fail before the tap fires, so a quick tap
    /// expands the control instead of being eaten as a micro-drag.
    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        guard gestureRecognizer === panGesture, otherGestureRecognizer === tapGesture else { return false }
        return true
    }
}
