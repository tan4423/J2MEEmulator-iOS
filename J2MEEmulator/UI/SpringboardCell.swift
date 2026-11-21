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
    // Static green activity dot; no animation or polling.
    private let liveDot = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)

        contentView.clipsToBounds = false

        // Icon — corners are pre-rendered into the image, no layer masking needed
        iconView.contentMode = .scaleAspectFill
        iconView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(iconView)

        liveDot.backgroundColor = UIColor.systemGreen
        liveDot.layer.cornerRadius = 7
        liveDot.layer.borderWidth = 2
        liveDot.layer.borderColor = UIColor(white: 0.12, alpha: 1).cgColor
        liveDot.isHidden = true
        liveDot.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(liveDot)

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
            liveDot.widthAnchor.constraint(equalToConstant: 14),
            liveDot.heightAnchor.constraint(equalToConstant: 14),
            liveDot.topAnchor.constraint(equalTo: iconView.topAnchor, constant: -3),
            liveDot.trailingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 4),

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
        liveDot.isHidden = true
        accessibilityValue = nil
    }

    // Instant touch feedback. No animation transaction or scaling.
    override var isHighlighted: Bool {
        didSet { iconView.alpha = isHighlighted ? 0.7 : 1.0 }
    }

    func configure(name: String, icon: UIImage, running: Bool = false) {
        iconView.image = icon
        nameLabel.text = name
        liveDot.isHidden = !running
        accessibilityLabel = name
        accessibilityValue = running ? "Đang chạy ẩn trong JarBox" : nil
    }
}
