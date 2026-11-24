//
//  SpringboardCell.swift
//  J2MEEmulator
//

import UIKit

class SpringboardCell: UICollectionViewCell {

    static let reuseID = "SpringboardCell"
    static let iconSize: CGFloat = 62
    static let iconCornerRadius: CGFloat = 14

    let iconView = UIImageView()
    let nameLabel = UILabel()
    // Static tab-count badge; no animation, blur, or polling.
    private let tabBadge = UIView()
    private let tabBadgeLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)

        contentView.clipsToBounds = false

        // Icon — corners are pre-rendered into the image, no layer masking needed
        iconView.contentMode = .scaleAspectFill
        iconView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(iconView)

        tabBadge.backgroundColor = UIColor(white: 0.16, alpha: 1)
        tabBadge.layer.cornerRadius = 6
        tabBadge.layer.borderWidth = 0.5
        tabBadge.layer.borderColor = UIColor(white: 1, alpha: 0.19).cgColor
        tabBadge.isHidden = true
        tabBadge.isUserInteractionEnabled = false
        tabBadge.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(tabBadge)

        tabBadgeLabel.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)
        tabBadgeLabel.textColor = .white
        tabBadgeLabel.textAlignment = .center
        tabBadgeLabel.translatesAutoresizingMaskIntoConstraints = false
        tabBadge.addSubview(tabBadgeLabel)

        // Static text: no shadow blur or offscreen text effect.
        nameLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        nameLabel.textColor = .white
        nameLabel.textAlignment = .center
        nameLabel.numberOfLines = 2
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(nameLabel)

        NSLayoutConstraint.activate([
            iconView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 2),
            iconView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: Self.iconSize),
            iconView.heightAnchor.constraint(equalToConstant: Self.iconSize),
            tabBadge.heightAnchor.constraint(equalToConstant: 18),
            tabBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 23),
            tabBadge.topAnchor.constraint(equalTo: iconView.topAnchor, constant: -2),
            tabBadge.leadingAnchor.constraint(equalTo: iconView.leadingAnchor, constant: -3),
            tabBadgeLabel.centerYAnchor.constraint(equalTo: tabBadge.centerYAnchor),
            tabBadgeLabel.leadingAnchor.constraint(equalTo: tabBadge.leadingAnchor, constant: 5),
            tabBadgeLabel.trailingAnchor.constraint(equalTo: tabBadge.trailingAnchor, constant: -5),

            nameLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 5),
            nameLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: -2),
            nameLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: 2),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        iconView.image = nil
        nameLabel.text = nil
        tabBadge.isHidden = true
        tabBadgeLabel.text = nil
        accessibilityLabel = nil
        accessibilityValue = nil
    }

    // Instant touch feedback. No animation transaction or scaling.
    override var isHighlighted: Bool {
        didSet { iconView.alpha = isHighlighted ? 0.7 : 1.0 }
    }

    func configure(name: String, icon: UIImage, tabCount: Int, running: Bool = false) {
        iconView.image = icon
        nameLabel.text = name
        tabBadgeLabel.text = tabCount >= 2 ? "x" + String(tabCount) : nil
        tabBadge.isHidden = tabCount < 2
        accessibilityLabel = name
        // Keep the running state available to VoiceOver without a visual dot.
        var details: [String] = []
        if tabCount >= 2 { details.append(String(tabCount) + " tab") }
        if running { details.append("Đang chạy ẩn trong JarBox") }
        accessibilityValue = details.isEmpty ? nil : details.joined(separator: ", ")
    }
}
