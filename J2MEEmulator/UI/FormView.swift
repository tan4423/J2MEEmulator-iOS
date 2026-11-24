//
//  FormView.swift
//  J2MEEmulator
//
//  Displays J2ME Forms/Lists/Alerts using native UIKit views.
//  Mirrors J2ME-Loader's approach of using Android native widgets.
//

import UIKit

class FormView: UIView {

    private let scrollView = UIScrollView()
    private let stackView = UIStackView()
    private let titleLabel = UILabel()
    private var commandButtons: [UIButton] = []
    private let commandBar = UIStackView()
    private let extraCommands = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        backgroundColor = .systemBackground

        // Title
        titleLabel.font = .boldSystemFont(ofSize: 18)
        titleLabel.textAlignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        // Scroll + Stack for items
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        stackView.axis = .vertical
        stackView.spacing = 12
        stackView.alignment = .fill
        stackView.layoutMargins = UIEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        stackView.isLayoutMarginsRelativeArrangement = true
        stackView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stackView)

        // Command bar at bottom
        commandBar.axis = .horizontal
        commandBar.spacing = 12
        commandBar.distribution = .fillEqually
        commandBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(commandBar)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 8),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),

            scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: commandBar.topAnchor, constant: -8),

            stackView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            stackView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),

            commandBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            commandBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            commandBar.bottomAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor, constant: -8),
            commandBar.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    /// Build the form from native bridge data.
    private var editableFields: [UITextField] = []
    private var choiceSelections: [Int: Int] = [:]
    private var fieldLimits: [Int: Int] = [:]

    private var screenRevision: Int32 = 0
    private var screenOwnerKey: UInt64 = 0

    func buildFromNativeData(ownerKey: UInt64) {
        screenOwnerKey = ownerKey
        screenRevision = j2me_ui_revision()
        // Clear previous content
        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        commandBar.arrangedSubviews.forEach { $0.removeFromSuperview() }
        commandButtons.removeAll()
        editableFields.removeAll()
        choiceSelections.removeAll()
        fieldLimits.removeAll()

        // Title
        titleLabel.text = String(cString: j2me_ui_get_form_title())

        // Items
        let count = j2me_ui_get_form_item_count()
        for i in 0..<count {
            let itemType = j2me_ui_get_form_item_type(Int32(i))
            let label = String(cString: j2me_ui_get_form_item_label(Int32(i)))
            let text = String(cString: j2me_ui_get_form_item_text(Int32(i)))

            switch itemType {
            case 0: // StringItem
                addStringItem(label: label, text: text)
            case 1: // TextField
                fieldLimits[Int(i)] = max(0, Int(j2me_ui_get_form_item_param1(i)))
                addTextField(label: label, text: text, index: Int(i))
            case 2:
                addChoice(label: label, index: Int(i))
            default:
                addStringItem(label: label, text: text) // fallback
            }
        }

        // Commands
        let revision = screenRevision
        let commandOwner = screenOwnerKey
        let cmdCount = j2me_ui_get_command_count()
        var overflow: [UIAction] = []
        for i in 0..<cmdCount {
            let cmdLabel = String(cString: j2me_ui_get_command_label(Int32(i)))
            let cmdId = j2me_ui_get_command_id(Int32(i))

            let keepVisible = cmdCount <= 2 || cmdLabel == "Lưu" || cmdLabel == "Quay lại"
            if !keepVisible {
                overflow.append(UIAction(title: cmdLabel) { [weak self] _ in
                    self?.sendFormCommand(cmdId, revision: revision, ownerKey: commandOwner)
                })
                continue
            }
            let btn = UIButton(type: .system)
            btn.titleLabel?.adjustsFontSizeToFitWidth = true
            btn.titleLabel?.minimumScaleFactor = 0.7
            btn.setTitle(cmdLabel, for: .normal)
            btn.titleLabel?.font = .boldSystemFont(ofSize: 16)
            btn.tag = Int(cmdId)
            btn.backgroundColor = .systemBlue
            btn.setTitleColor(.white, for: .normal)
            btn.layer.cornerRadius = 8
            btn.addTarget(self, action: #selector(commandTapped(_:)), for: .touchUpInside)
            commandBar.addArrangedSubview(btn)
            commandButtons.append(btn)
        }
        extraCommands.menu = UIMenu(children: overflow)
        if !overflow.isEmpty {
            extraCommands.setTitle("Thêm…", for: .normal)
            extraCommands.showsMenuAsPrimaryAction = true
            commandBar.addArrangedSubview(extraCommands)
        }
    }

    private func addChoice(label: String, index: Int) {
        let count = Int(j2me_ui_get_choice_count(Int32(index)))
        let options = (0..<count).map { String(cString: j2me_ui_get_choice_option(Int32(index), Int32($0))) }
        guard !options.isEmpty else {
            addStringItem(label: label, text: "Không có lựa chọn")
            return
        }
        let selected = Int(j2me_ui_get_form_item_param1(Int32(index)))
        choiceSelections[index] = options.indices.contains(selected) ? selected : 0

        let container = UIStackView()
        container.axis = .vertical
        container.spacing = 4
        let caption = UILabel()
        caption.text = label
        caption.font = .boldSystemFont(ofSize: 14)
        caption.textColor = .secondaryLabel
        container.addArrangedSubview(caption)

        let picker = UIButton(type: .system)
        picker.contentHorizontalAlignment = .leading
        picker.accessibilityLabel = label
        picker.showsMenuAsPrimaryAction = true
        picker.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        updateChoiceMenu(picker, index: index, options: options)
        container.addArrangedSubview(picker)
        stackView.addArrangedSubview(container)
    }

    private func updateChoiceMenu(_ picker: UIButton, index: Int, options: [String]) {
        let selected = choiceSelections[index] ?? 0
        picker.setTitle(options[selected] + "  ▾", for: .normal)
        picker.accessibilityValue = options[selected]
        picker.menu = UIMenu(children: options.enumerated().map { offset, name in
            UIAction(title: name, state: offset == selected ? .on : .off) { [weak self, weak picker] _ in
                guard let self, let picker else { return }
                self.choiceSelections[index] = offset
                self.updateChoiceMenu(picker, index: index, options: options)
            }
        })
    }

    private func addStringItem(label: String, text: String) {
        let container = UIStackView()
        container.axis = .vertical
        container.spacing = 2

        if !label.isEmpty {
            let labelView = UILabel()
            labelView.text = label
            labelView.font = .boldSystemFont(ofSize: 14)
            labelView.textColor = .secondaryLabel
            container.addArrangedSubview(labelView)
        }

        if !text.isEmpty {
            let textView = UILabel()
            textView.text = text
            textView.font = .systemFont(ofSize: 16)
            textView.numberOfLines = 0
            container.addArrangedSubview(textView)
        }

        stackView.addArrangedSubview(container)
    }

    private func addTextField(label: String, text: String, index: Int) {
        let container = UIStackView()
        container.axis = .vertical
        container.spacing = 4

        if !label.isEmpty {
            let labelView = UILabel()
            labelView.text = label
            labelView.font = .boldSystemFont(ofSize: 14)
            labelView.textColor = .secondaryLabel
            container.addArrangedSubview(labelView)
        }

        let tf = UITextField()
        tf.text = text
        tf.borderStyle = .roundedRect
        tf.font = .systemFont(ofSize: 16)
        tf.tag = index
        let flags = j2me_ui_get_form_item_param2(Int32(index))
        tf.isSecureTextEntry = (flags & 0x10000) != 0
        tf.isEnabled = (flags & 0x20000) == 0
        tf.autocapitalizationType = .none
        tf.autocorrectionType = .no
        editableFields.append(tf)
        container.addArrangedSubview(tf)

        stackView.addArrangedSubview(container)
    }

    @objc private func commandTapped(_ sender: UIButton) {
        guard commandButtons.contains(where: { $0 === sender }) else { return }
        sendFormCommand(Int32(sender.tag), revision: screenRevision, ownerKey: screenOwnerKey)
    }

    private func sendFormCommand(_ cmdId: Int32, revision: Int32, ownerKey: UInt64) {
        guard ownerKey != 0, ownerKey == screenOwnerKey,
              ownerKey == j2me_ui_focused_owner_key(), ownerKey == j2me_render_visible_owner_key(),
              revision == screenRevision, revision == j2me_ui_revision() else { return }
        endEditing(true)
        for field in editableFields where field.isEnabled {
            let limit = fieldLimits[field.tag] ?? 0
            let units = Array((field.text ?? "").utf16.prefix(limit))
            units.withUnsafeBufferPointer { p in
                j2me_ui_stage_text_for_owner(ownerKey, revision, Int32(field.tag), p.baseAddress, Int32(p.count))
            }
        }
        for (index, selection) in choiceSelections {
            let units = Array(String(selection).utf16)
            units.withUnsafeBufferPointer { p in
                j2me_ui_stage_text_for_owner(ownerKey, revision, Int32(index), p.baseAddress, Int32(p.count))
            }
        }
        j2me_input_post_touch_for_owner(ownerKey, Int32(J2ME_UI_COMMAND_ACTION), revision, cmdId)
    }

}

// ============================================================
// List view
// ============================================================

class J2MEListView: UIView, UITableViewDataSource, UITableViewDelegate {

    private let titleLabel = UILabel()
    private let tableView = UITableView()
    private var items: [String] = []
    private var icons: [UIImage?] = []
    private var selectedRow: Int?
    private let actionsButton = UIButton(type: .system)
    private let launchButton = UIButton(type: .system)
    private let commandBar = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        backgroundColor = .systemBackground

        titleLabel.font = .boldSystemFont(ofSize: 18)
        titleLabel.textAlignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        tableView.dataSource = self
        tableView.delegate = self
        tableView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tableView)

        commandBar.axis = .horizontal
        commandBar.spacing = 12
        commandBar.distribution = .fillEqually
        commandBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(commandBar)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 8),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),

            tableView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            tableView.leadingAnchor.constraint(equalTo: leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: commandBar.topAnchor, constant: -8),

            commandBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            commandBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            commandBar.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -8),
            commandBar.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    private var screenRevision: Int32 = 0
    private var screenOwnerKey: UInt64 = 0

    func buildFromNativeData(ownerKey: UInt64) {
        screenOwnerKey = ownerKey
        screenRevision = j2me_ui_revision()
        titleLabel.text = String(cString: j2me_ui_get_form_title())

        items.removeAll()
        icons.removeAll()
        let count = j2me_ui_get_list_item_count()
        for i in 0..<count {
            items.append(String(cString: j2me_ui_get_list_item(Int32(i))))
            icons.append(j2me_ui_copy_list_icon(Int32(i)).map { UIImage(cgImage: $0) })
        }
        tableView.reloadData()

        selectedRow = nil
        commandBar.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let revision = screenRevision
        let commandOwner = screenOwnerKey
        var actions: [UIAction] = []
        var launchID: Int32?
        for i in 0..<j2me_ui_get_command_count() {
            let label = String(cString: j2me_ui_get_command_label(i))
            let id = j2me_ui_get_command_id(i)
            let normalized = label.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "vi"))
            if normalized == "chay ung dung" || normalized == "run application" {
                launchID = id
            }
            actions.append(UIAction(title: label) { [weak self] _ in
                self?.sendCommand(id, revision: revision, ownerKey: commandOwner)
            })
        }
        if let launchID {
            launchButton.tag = Int(launchID)
            launchButton.setTitle("Chạy ứng dụng", for: .normal)
            launchButton.removeTarget(self, action: #selector(commandTapped(_:)), for: .touchUpInside)
            launchButton.addTarget(self, action: #selector(commandTapped(_:)), for: .touchUpInside)
            commandBar.addArrangedSubview(launchButton)
        }
        actionsButton.setTitle("Menu", for: .normal)
        actionsButton.showsMenuAsPrimaryAction = true
        actionsButton.menu = UIMenu(children: actions)
        if !actions.isEmpty { commandBar.addArrangedSubview(actionsButton) }
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { items.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell") ?? UITableViewCell(style: .default, reuseIdentifier: "cell")
        var content = cell.defaultContentConfiguration()
        content.text = items[indexPath.row]
        content.image = icons[indexPath.row]
        content.imageProperties.maximumSize = CGSize(width: 48, height: 48)
        cell.contentConfiguration = content
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard screenOwnerKey != 0,
              screenOwnerKey == j2me_ui_focused_owner_key(),
              screenOwnerKey == j2me_render_visible_owner_key(),
              screenRevision == j2me_ui_revision() else { return }
        selectedRow = indexPath.row
        j2me_input_post_touch_for_owner(screenOwnerKey, Int32(J2ME_UI_LIST_SELECT), screenRevision, Int32(indexPath.row))
    }

    @objc private func commandTapped(_ sender: UIButton) {
        sendCommand(Int32(sender.tag), revision: screenRevision, ownerKey: screenOwnerKey)
    }

    private func sendCommand(_ id: Int32, revision: Int32, ownerKey: UInt64) {
        guard ownerKey != 0, ownerKey == screenOwnerKey,
              ownerKey == j2me_ui_focused_owner_key(), ownerKey == j2me_render_visible_owner_key(),
              revision == screenRevision, revision == j2me_ui_revision() else { return }
        // Commit the highlighted row immediately before invoking the MIDlet's action.
        if let selectedRow {
            j2me_input_post_touch_for_owner(ownerKey, Int32(J2ME_UI_LIST_SELECT), revision, -Int32(selectedRow) - 1)
        }
        j2me_input_post_touch_for_owner(ownerKey, Int32(J2ME_UI_COMMAND_ACTION), revision, id)
    }
}
