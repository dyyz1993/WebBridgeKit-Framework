//
//  HUDService.swift
//  WebBridgeKit
//
//  Lightweight HUD service replacing SVProgressHUD with native UIKit.
//

import UIKit

public final class HUDService {

    public static let shared = HUDService()

    private var hudWindow: UIWindow?
    private var hudView: HUDContainerView?
    private var dismissWorkItem: DispatchWorkItem?
    private var presentationGeneration: UInt = 0

    private let animationDuration: TimeInterval = ThemeTokens.Animation.normal.duration
    private let successDisplayDuration: TimeInterval = 1.5

    private init() {}

    // MARK: - Public API

    public func show(_ status: String? = nil) {
        DispatchQueue.main.async { [self] in
            showHUD(status: status, style: .`default`)
        }
    }

    public func showProgress(_ progress: Float, status: String? = nil) {
        DispatchQueue.main.async { [self] in
            showHUD(status: status, style: .progress(progress))
        }
    }

    public func showSuccess(withStatus status: String) {
        DispatchQueue.main.async { [self] in
            showHUD(status: status, style: .success)
            scheduleAutoDismiss(delay: successDisplayDuration)
        }
    }

    public func showError(withStatus status: String) {
        DispatchQueue.main.async { [self] in
            showHUD(status: status, style: .error)
            scheduleAutoDismiss(delay: successDisplayDuration)
        }
    }

    public func showInfo(withStatus status: String) {
        DispatchQueue.main.async { [self] in
            showHUD(status: status, style: .info)
            scheduleAutoDismiss(delay: successDisplayDuration)
        }
    }

    public func setStatus(_ status: String) {
        DispatchQueue.main.async { [self] in
            hudView?.updateStatus(status)
        }
    }

    public func dismiss() {
        DispatchQueue.main.async { [self] in
            dismissAnimated()
        }
    }

    public func dismiss(withDelay delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in
            dismissAnimated()
        }
    }

    // MARK: - Private

    enum HUDStyle {
        case `default`
        case progress(Float)
        case success
        case error
        case info
    }

    private func showHUD(status: String?, style: HUDStyle) {
        cancelAutoDismiss()
        presentationGeneration &+= 1

        let window = makeWindow()
        self.hudWindow = window
        switch style {
        case .success, .error, .info:
            window.isUserInteractionEnabled = false
        case .default, .progress:
            window.isUserInteractionEnabled = true
        }

        // A progress state is commonly replaced immediately by success/error.
        // Remove the previous container before adding the replacement so rapid
        // transitions can never leave two or three toast cards stacked.
        hudView?.removeFromSuperview()
        let container = HUDContainerView()
        container.configure(status: status, style: style)
        self.hudView = container

        window.addSubview(container)
        container.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            container.centerXAnchor.constraint(equalTo: window.centerXAnchor),
            container.centerYAnchor.constraint(equalTo: window.centerYAnchor),
            container.leadingAnchor.constraint(greaterThanOrEqualTo: window.leadingAnchor, constant: 20),
            container.trailingAnchor.constraint(lessThanOrEqualTo: window.trailingAnchor, constant: -20)
        ])

        window.alpha = 0
        if UIAccessibility.isReduceMotionEnabled {
            window.alpha = 1
        } else {
            UIView.animate(withDuration: animationDuration) {
                window.alpha = 1
            }
        }
    }

    private func dismissAnimated() {
        guard let window = hudWindow else { return }

        cancelAutoDismiss()
        let generation = presentationGeneration

        if UIAccessibility.isReduceMotionEnabled {
            window.isHidden = true
            self.hudView = nil
            self.hudWindow = nil
        } else {
            UIView.animate(
                withDuration: animationDuration,
                animations: {
                    window.alpha = 0
                },
                completion: { [weak self] _ in
                    guard let self, self.presentationGeneration == generation else { return }
                    window.isHidden = true
                    self.hudView = nil
                    self.hudWindow = nil
                }
            )
        }
    }

    private func scheduleAutoDismiss(delay: TimeInterval) {
        cancelAutoDismiss()
        let item = DispatchWorkItem { [weak self] in
            self?.dismissAnimated()
        }
        dismissWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func cancelAutoDismiss() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
    }

    @MainActor
    var activePresentationCountForTesting: Int {
        hudWindow?.subviews.filter { $0 is HUDContainerView }.count ?? 0
    }

    private func makeWindow() -> UIWindow {
        if let existing = hudWindow {
            existing.isHidden = false
            existing.alpha = 1
            return existing
        }

        let windowScene: UIWindowScene?
        if #available(iOS 15.0, *) {
            windowScene = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive }
                ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        } else {
            windowScene = UIApplication.shared.windows.first?.windowScene
        }

        let window: UIWindow
        if let scene = windowScene {
            window = UIWindow(windowScene: scene)
        } else {
            window = UIWindow(frame: UIScreen.main.bounds)
        }

        window.windowLevel = .statusBar + 1
        window.backgroundColor = .clear
        window.isHidden = false
        return window
    }
}

// MARK: - HUDContainerView

private final class HUDContainerView: UIView {

    private let backgroundView = UIView()
    private let contentView = UIView()
    private let iconView = UIImageView()
    private let statusLabel = UILabel()
    private let progressView = UIProgressView(progressViewStyle: .default)
    private let stack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            backgroundView.layer.borderColor = ThemeTokens.Color.border.resolvedColor(with: traitCollection).cgColor
        }
    }

    private func setupViews() {
        backgroundView.backgroundColor = ThemeTokens.Color.surfaceElevated
        backgroundView.layer.cornerRadius = ThemeTokens.CornerRadius.lg
        backgroundView.layer.borderWidth = 1
        backgroundView.layer.borderColor = ThemeTokens.Color.border.cgColor
        backgroundView.layer.shadowColor = UIColor.black.cgColor
        backgroundView.layer.shadowOpacity = 0.15
        backgroundView.layer.shadowRadius = 12
        backgroundView.layer.shadowOffset = CGSize(width: 0, height: 5)

        contentView.backgroundColor = .clear

        iconView.contentMode = .scaleAspectFit
        iconView.tintColor = ThemeTokens.Color.textOnColor

        statusLabel.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: .systemFont(ofSize: 14, weight: .medium))
        statusLabel.textColor = ThemeTokens.Color.text
        statusLabel.textAlignment = .natural
        statusLabel.numberOfLines = 0
        statusLabel.adjustsFontForContentSizeCategory = true

        progressView.progressTintColor = ThemeTokens.Color.primary
        progressView.trackTintColor = ThemeTokens.Color.overlaySoft
        progressView.layer.cornerRadius = ThemeTokens.CornerRadius.xs
        progressView.clipsToBounds = true

        [iconView, progressView, statusLabel].forEach { stack.addArrangedSubview($0) }
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = ThemeTokens.Spacing.sm

        backgroundView.addSubview(stack)
        addSubview(backgroundView)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        progressView.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        backgroundView.translatesAutoresizingMaskIntoConstraints = false

        let progressWidth = progressView.widthAnchor.constraint(equalToConstant: 120)
        let progressHeight = progressView.heightAnchor.constraint(equalToConstant: 4)
        progressWidth.priority = .defaultHigh
        progressHeight.priority = .defaultHigh

        NSLayoutConstraint.activate([
            backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backgroundView.topAnchor.constraint(equalTo: topAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),

            stack.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: backgroundView.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: backgroundView.bottomAnchor, constant: -14),

            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24),

            progressWidth,
            progressHeight
        ])
    }

    func configure(status: String?, style: HUDService.HUDStyle) {
        switch style {
        case .`default`:
            stack.axis = .vertical
            statusLabel.textAlignment = .center
            iconView.image = nil
            configureActivityIndicator()
            progressView.isHidden = true
        case .progress(let progress):
            stack.axis = .vertical
            statusLabel.textAlignment = .center
            iconView.image = nil
            removeActivityIndicator()
            progressView.isHidden = false
            progressView.setProgress(progress, animated: true)
        case .success:
            stack.axis = .horizontal
            iconView.tintColor = ThemeTokens.Color.success
            iconView.image = LucideIcon.success.templateImage()
            removeActivityIndicator()
            progressView.isHidden = true
        case .error:
            stack.axis = .horizontal
            iconView.tintColor = ThemeTokens.Color.error
            iconView.image = LucideIcon.error.templateImage()
            removeActivityIndicator()
            progressView.isHidden = true
        case .info:
            stack.axis = .horizontal
            iconView.tintColor = ThemeTokens.Color.info
            iconView.image = LucideIcon.info.templateImage()
            removeActivityIndicator()
            progressView.isHidden = true
        }

        statusLabel.text = status
        statusLabel.isHidden = (status == nil)
    }

    func updateStatus(_ status: String) {
        statusLabel.text = status
        statusLabel.isHidden = status.isEmpty
    }

    private var activityIndicator: UIActivityIndicatorView?

    private func configureActivityIndicator() {
        removeActivityIndicator()
        let indicator = UIActivityIndicatorView(style: .large)
        indicator.color = ThemeTokens.Color.primary
        indicator.startAnimating()
        indicator.translatesAutoresizingMaskIntoConstraints = false

        insertSubview(indicator, aboveSubview: backgroundView)

        indicator.centerXAnchor.constraint(equalTo: iconView.centerXAnchor).isActive = true
        indicator.centerYAnchor.constraint(equalTo: iconView.centerYAnchor).isActive = true
        indicator.widthAnchor.constraint(equalToConstant: 24).isActive = true
        indicator.heightAnchor.constraint(equalToConstant: 24).isActive = true

        // iconView 保持参与布局（image 为 nil 即不可见）作为指示器的居中锚点；
        // 若 isHidden=true，UIStackView 会把它踢出布局，指示器漂向容器角落。
        iconView.image = nil
        iconView.isHidden = false
        activityIndicator = indicator
    }

    private func removeActivityIndicator() {
        activityIndicator?.stopAnimating()
        activityIndicator?.removeFromSuperview()
        activityIndicator = nil
        iconView.isHidden = false
    }
}
