import SwiftUI
import Combine

/// File-renaming feature settings: global hotkey, cleanup flags, .eml date
/// extraction, folder-handling preferences, and the permission-denied banner.
struct FileRenamingSettingsPage: View {
    @StateObject private var permissions = PermissionsManager.shared

    @State private var isRecordingPrimary = false
    @State private var isRecordingSecondary = false
    @State private var primaryHotkeyLabel = HotkeyManager.shared.currentShortcutLabel
    @State private var secondaryHotkeyLabel = HotkeyManager.shared.secondaryShortcutLabel
    @State private var secondaryEnabled = HotkeyManager.shared.secondaryEnabled

    @AppStorage(DefaultsKeys.cleanupTrimStem) private var trimStemWhitespace = false
    @AppStorage(DefaultsKeys.emlUseDateHeader) private var emlUseDateHeader = true
    @AppStorage(DefaultsKeys.folderMode) private var folderModeRaw = FolderModePreference.default.rawValue
    @AppStorage(DefaultsKeys.recursiveWarnEnabled) private var recursiveWarnEnabled = true
    @AppStorage(DefaultsKeys.recursiveWarnThreshold) private var recursiveWarnThreshold = AppController.defaultRecursiveWarnThreshold

    @AppStorage(DefaultsKeys.dateFormatStyle) private var dateFormatStyleRaw = DateFormatStyle.default.rawValue
    @AppStorage(DefaultsKeys.datePriority) private var datePriorityRaw = DatePriority.default.rawValue
    @AppStorage(DefaultsKeys.dateAmbiguityOrder) private var dateAmbiguityOrderRaw = DateAmbiguityOrder.default.rawValue

    @AppStorage(DefaultsKeys.pdfUseContentDate) private var pdfUseContentDate = true
    @AppStorage(DefaultsKeys.pdfConflictBehavior) private var pdfConflictBehaviorRaw = PdfConflictBehavior.default.rawValue
    @AppStorage(DefaultsKeys.pdfNoDateBehavior) private var pdfNoDateBehaviorRaw = PdfNoDateBehavior.default.rawValue
    @AppStorage(DefaultsKeys.pdfConflictToleranceDays) private var pdfConflictToleranceDays = 7
    @AppStorage(DefaultsKeys.pdfUseOcrFallback) private var pdfUseOcrFallback = true

    private var folderMode: Binding<FolderModePreference> {
        Binding(
            get: { FolderModePreference(rawValue: folderModeRaw) ?? .default },
            set: { folderModeRaw = $0.rawValue }
        )
    }

    private var dateFormatStyle: Binding<DateFormatStyle> {
        Binding(
            get: { DateFormatStyle(rawValue: dateFormatStyleRaw) ?? .default },
            set: { dateFormatStyleRaw = $0.rawValue }
        )
    }

    private var datePriority: Binding<DatePriority> {
        Binding(
            get: { DatePriority(rawValue: datePriorityRaw) ?? .default },
            set: { datePriorityRaw = $0.rawValue }
        )
    }

    private var dateAmbiguityOrder: Binding<DateAmbiguityOrder> {
        Binding(
            get: { DateAmbiguityOrder(rawValue: dateAmbiguityOrderRaw) ?? .default },
            set: { dateAmbiguityOrderRaw = $0.rawValue }
        )
    }

    /// Today's date rendered in `style`, used to preview format choices live
    /// in the picker. Recomputed per render so changing the locale at runtime
    /// is reflected without restart.
    private func previewSample(_ style: DateFormatStyle) -> String {
        style.format(FilenameBuilder.todayComponents())
    }

    private var pdfConflictBehavior: Binding<PdfConflictBehavior> {
        Binding(
            get: { PdfConflictBehavior(rawValue: pdfConflictBehaviorRaw) ?? .default },
            set: { pdfConflictBehaviorRaw = $0.rawValue }
        )
    }

    private var pdfNoDateBehavior: Binding<PdfNoDateBehavior> {
        Binding(
            get: { PdfNoDateBehavior(rawValue: pdfNoDateBehaviorRaw) ?? .default },
            set: { pdfNoDateBehaviorRaw = $0.rawValue }
        )
    }

    var body: some View {
        Form {
            Section("Hotkey") {
                HotkeyRow(
                    title: secondaryEnabled ? "Rename (non-recursive)" : "Global Shortcut",
                    label: primaryHotkeyLabel,
                    isRecording: $isRecordingPrimary,
                    onNewShortcut: { keyCode, modifiers in
                        HotkeyManager.shared.update(keyCode: keyCode, modifiers: modifiers)
                        primaryHotkeyLabel = HotkeyManager.shared.currentShortcutLabel
                    }
                )

                LabeledContent {
                    Toggle("", isOn: Binding(
                        get: { secondaryEnabled },
                        set: { newValue in
                            HotkeyManager.shared.setSecondaryEnabled(newValue)
                            secondaryEnabled = newValue
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                } label: {
                    HStack(spacing: 6) {
                        Text("Use second hotkey for recursive rename")
                        InfoPopover(
                            title: "Two-hotkey mode",
                            detail: "When enabled, the primary hotkey renames only the selection (folders are renamed by their own name; contents are left alone). The second hotkey renames recursively — folders and everything inside them. Neither prompts; the choice is the keystroke.",
                            exampleBefore: nil,
                            exampleAfter: nil
                        )
                    }
                }

                if secondaryEnabled {
                    HotkeyRow(
                        title: "Rename (recursive)",
                        label: secondaryHotkeyLabel,
                        isRecording: $isRecordingSecondary,
                        onNewShortcut: { keyCode, modifiers in
                            HotkeyManager.shared.updateSecondary(keyCode: keyCode, modifiers: modifiers)
                            secondaryHotkeyLabel = HotkeyManager.shared.secondaryShortcutLabel
                        }
                    )
                }
            }

            Section("Date format") {
                LabeledContent {
                    Picker("", selection: dateFormatStyle) {
                        ForEach(DateFormatStyle.allCases, id: \.self) { style in
                            Text("\(style.displayName) — \(previewSample(style))")
                                .tag(style)
                        }
                    }
                    .labelsHidden()
                } label: {
                    HStack(spacing: 6) {
                        Text("Output format")
                        InfoPopover(
                            title: "Date prefix format",
                            detail: "Controls how the date prefix is written into new filenames. \"Follow system region\" mirrors the format set in System Settings → General → Language & Region, with the year forced to four digits. Slashes are replaced with dashes because \"/\" isn't allowed in macOS filenames. Existing date prefixes are re-formatted to this style on the next rename.",
                            exampleBefore: "01.01.2024 Invoice.pdf",
                            exampleAfter: "2024-01-01 Invoice.pdf"
                        )
                    }
                }

                LabeledContent {
                    Picker("", selection: dateAmbiguityOrder) {
                        ForEach(DateAmbiguityOrder.allCases, id: \.self) { order in
                            Text(order.displayName).tag(order)
                        }
                    }
                    .labelsHidden()
                } label: {
                    HStack(spacing: 6) {
                        Text("Interpret ambiguous dates as")
                        InfoPopover(
                            title: "Ambiguous date order",
                            detail: "When a filename starts with a purely numeric date whose order isn't obvious (e.g. \"12-05-2012\"), this setting decides whether the first field is the day or the month. Unambiguous shapes like \"2012-05-12\" or \"2012_05_12\" are recognized regardless.",
                            exampleBefore: "12-05-2012 Screenshot.png",
                            exampleAfter: "2012-05-12 Screenshot.png"
                        )
                    }
                }
            }

            Section("Date priority") {
                LabeledContent {
                    Picker("", selection: datePriority) {
                        Text("Let content extraction override").tag(DatePriority.contentOverridesFilename)
                        Text("Trust existing filename date").tag(DatePriority.filenameWins)
                    }
                    .labelsHidden()
                } label: {
                    HStack(spacing: 6) {
                        Text("When filename and document disagree")
                        InfoPopover(
                            title: "Date priority",
                            detail: "When the filename already starts with a recognizable date AND the email header or PDF contents yield a different one, this setting decides which wins. \"Content extraction\" is best when downloads or exports leave wrong filename dates. \"Filename date\" is best when you curate filenames manually and want the existing prefix preserved — the date is just re-formatted, and email/PDF date extraction is skipped.",
                            exampleBefore: "2024-01-01 Invoice.pdf  (PDF body: 03.05.2024)",
                            exampleAfter: "2024-05-03 Invoice.pdf  (content wins)"
                        )
                    }
                }
            }

            Section("Folders") {
                LabeledContent {
                    Picker("", selection: folderMode) {
                        Text("Ask each time").tag(FolderModePreference.ask)
                        Text("Rename folder only").tag(FolderModePreference.flat)
                        Text("Rename recursively").tag(FolderModePreference.recursive)
                    }
                    .labelsHidden()
                    .disabled(secondaryEnabled)
                } label: {
                    HStack(spacing: 6) {
                        Text("When selection contains folders")
                        InfoPopover(
                            title: "Folder handling",
                            detail: secondaryEnabled
                                ? "Disabled while the second hotkey is enabled — each hotkey already picks recursive vs. non-recursive."
                                : "Controls what happens when the Finder selection contains a folder. \"Ask\" prompts each time, \"folder only\" renames just the folder itself, \"recursively\" descends into the folder and renames every file and subfolder inside it. Hidden files (.DS_Store, dotfiles) are always skipped.",
                            exampleBefore: nil,
                            exampleAfter: nil
                        )
                    }
                }

                LabeledContent {
                    Toggle("", isOn: $recursiveWarnEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                } label: {
                    HStack(spacing: 6) {
                        Text("Confirm large recursive batches")
                        InfoPopover(
                            title: "Recursive batch confirmation",
                            detail: "Recursive batches larger than the threshold below require an extra confirmation dialog before they run. Turn off to skip the prompt entirely — only do this if you're confident you won't trigger a recursive rename on the wrong folder; there's no per-file undo for a batch that runs unattended.",
                            exampleBefore: nil,
                            exampleAfter: nil
                        )
                    }
                }

                if recursiveWarnEnabled {
                    LabeledContent {
                        Stepper(
                            value: $recursiveWarnThreshold,
                            in: 1...10_000,
                            step: 10
                        ) {
                            Text("\(recursiveWarnThreshold) items")
                                .monospacedDigit()
                                .frame(minWidth: 80, alignment: .trailing)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text("Confirm above")
                            InfoPopover(
                                title: "Confirmation threshold",
                                detail: "Recursive batches at or below this item count (files + folders combined) run without an extra prompt. Set higher if you regularly rename large folders and find the prompt annoying.",
                                exampleBefore: nil,
                                exampleAfter: nil
                            )
                        }
                    }
                }
            }

            Section("Cleanup") {
                LabeledContent {
                    Toggle("", isOn: $trimStemWhitespace)
                        .labelsHidden()
                        .toggleStyle(.switch)
                } label: {
                    HStack(spacing: 6) {
                        Text("Remove space before extension")
                        InfoPopover(
                            title: "Remove space before extension",
                            detail: "Strips a trailing space from the filename stem before renaming.",
                            exampleBefore: "\"Report .pdf\"",
                            exampleAfter: "\"Report.pdf\""
                        )
                    }
                }
            }

            Section("Email (.eml)") {
                LabeledContent {
                    Toggle("", isOn: $emlUseDateHeader)
                        .labelsHidden()
                        .toggleStyle(.switch)
                } label: {
                    HStack(spacing: 6) {
                        Text("Extract date from email headers")
                        InfoPopover(
                            title: "Email date extraction",
                            detail: "Reads the Date: header from the .eml file and uses it as the file's date prefix instead of the filesystem modification date.",
                            exampleBefore: "\"Invoice.eml\"",
                            exampleAfter: "\"2024-03-15 Invoice.eml\""
                        )
                    }
                }
            }

            Section("PDF") {
                LabeledContent {
                    Toggle("", isOn: $pdfUseContentDate)
                        .labelsHidden()
                        .toggleStyle(.switch)
                } label: {
                    HStack(spacing: 6) {
                        Text("Extract date from PDF contents")
                        InfoPopover(
                            title: "PDF date extraction",
                            detail: "Reads the document text (and PDF creation-date metadata) to detect invoice-style dates like \"Rechnungsdatum: 03.05.2024\" or \"Invoice Date: 2024-05-03\". When both sources agree, the rename runs silently. When they disagree, the behavior below decides what happens.",
                            exampleBefore: "\"Invoice.pdf\"",
                            exampleAfter: "\"2024-05-03 Invoice.pdf\""
                        )
                    }
                }

                LabeledContent {
                    Picker("", selection: pdfConflictBehavior) {
                        Text("Ask each time").tag(PdfConflictBehavior.ask)
                        Text("Use document text").tag(PdfConflictBehavior.preferHeuristic)
                        Text("Use file metadata").tag(PdfConflictBehavior.preferMetadata)
                    }
                    .labelsHidden()
                    .disabled(!pdfUseContentDate)
                } label: {
                    HStack(spacing: 6) {
                        Text("When sources disagree")
                        InfoPopover(
                            title: "Conflict behavior",
                            detail: "What to do when the date found in the document text doesn't match the PDF's metadata creation date (outside the tolerance window below). \"Document text\" is usually the right answer for invoices — metadata reflects when the PDF was generated, which may be a reprint.",
                            exampleBefore: nil,
                            exampleAfter: nil
                        )
                    }
                }

                LabeledContent {
                    Picker("", selection: pdfNoDateBehavior) {
                        Text("Ask each time").tag(PdfNoDateBehavior.ask)
                        Text("Use file metadata").tag(PdfNoDateBehavior.metadata)
                        Text("Use today's date").tag(PdfNoDateBehavior.today)
                    }
                    .labelsHidden()
                    .disabled(!pdfUseContentDate)
                } label: {
                    HStack(spacing: 6) {
                        Text("When no date is found in text")
                        InfoPopover(
                            title: "No-date behavior",
                            detail: "What to do when the heuristic finds nothing date-shaped in the document. Metadata is usually accurate for digitally-generated PDFs; choose \"today\" if you'd rather not trust metadata at all.",
                            exampleBefore: nil,
                            exampleAfter: nil
                        )
                    }
                }

                LabeledContent {
                    Stepper(
                        value: $pdfConflictToleranceDays,
                        in: 0...365,
                        step: 1
                    ) {
                        Text("\(pdfConflictToleranceDays) day\(pdfConflictToleranceDays == 1 ? "" : "s")")
                            .monospacedDigit()
                            .frame(minWidth: 80, alignment: .trailing)
                    }
                    .disabled(!pdfUseContentDate)
                } label: {
                    HStack(spacing: 6) {
                        Text("Treat sources as agreeing within")
                        InfoPopover(
                            title: "Conflict tolerance",
                            detail: "Document and metadata dates within this many days of each other are treated as agreeing and no prompt is shown. Larger windows are more forgiving (fewer prompts), smaller windows are stricter.",
                            exampleBefore: nil,
                            exampleAfter: nil
                        )
                    }
                }

                LabeledContent {
                    Toggle("", isOn: $pdfUseOcrFallback)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(!pdfUseContentDate)
                } label: {
                    HStack(spacing: 6) {
                        Text("OCR scanned PDFs")
                        InfoPopover(
                            title: "OCR fallback",
                            detail: "When a PDF has no embedded text (typical of scanned invoices), run macOS's built-in text recognizer on the first page to look for a date. Adds about 200–500 ms per scanned PDF.",
                            exampleBefore: nil,
                            exampleAfter: nil
                        )
                    }
                }
            }

            if permissions.finderAutomationStatus == .denied {
                Section {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                        Text("Finder automation permission denied.")
                        Spacer()
                        Button("Open Settings") {
                            permissions.openSystemSettings()
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task {
            await permissions.checkPermission()
        }
    }
}
