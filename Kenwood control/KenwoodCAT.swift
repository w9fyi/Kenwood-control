import Foundation

enum KenwoodCAT {
    enum AutoInformationMode: Int {
        case off = 0
        /// AI ON (not backed up on radio power-off).
        case onNonPersistent = 2
        /// AI ON (backed up).
        case onPersistent = 4
    }

    static func getVFOAFrequency() -> String {
        "FA;"
    }

    static func setVFOAFrequencyHz(_ hz: Int) -> String {
        let clamped = max(0, min(hz, 999_999_999))
        return String(format: "FA%011d;", clamped)
    }

    static func getVFOBFrequency() -> String { "FB;" }

    static func setVFOBFrequencyHz(_ hz: Int) -> String {
        let clamped = max(0, min(hz, 999_999_999))
        return String(format: "FB%011d;", clamped)
    }

    static func setAutoInformation(_ mode: AutoInformationMode) -> String {
        "AI\(mode.rawValue);"
    }

    // MARK: - KNS VoIP Levels (requires administrator login for setting)

    static func getVoipInputLevel() -> String { "##KN30;" }
    static func getVoipOutputLevel() -> String { "##KN31;" }

    static func setVoipInputLevel(_ level: Int) -> String {
        let clamped = max(0, min(level, 100))
        return String(format: "##KN30%03d;", clamped)
    }

    static func setVoipOutputLevel(_ level: Int) -> String {
        let clamped = max(0, min(level, 100))
        return String(format: "##KN31%03d;", clamped)
    }

    // MARK: - AF Gain (Audio / Speaker Level)

    static func getAFGain() -> String { "AG;" }

    static func setAFGain(_ value: Int) -> String {
        let clamped = max(0, min(value, 255))
        return String(format: "AG%03d;", clamped)
    }

    // MARK: - Operating Mode (OM)

    enum FrequencyDisplayArea: Int {
        case left = 0
        case right = 1
    }

    enum OperatingMode: Int, CaseIterable {
        case lsb = 1
        case usb = 2
        case cw = 3
        case fm = 4
        case am = 5
        case fsk = 6
        case cwR = 7

        var label: String {
            switch self {
            case .lsb: "LSB"
            case .usb: "USB"
            case .cw: "CW"
            case .fm: "FM"
            case .am: "AM"
            case .fsk: "FSK"
            case .cwR: "CW-R"
            }
        }
    }

    static func getOperatingMode(_ area: FrequencyDisplayArea = .left) -> String {
        "OM\(area.rawValue);"
    }

    static func setOperatingMode(_ mode: OperatingMode) -> String {
        // Kenwood notes P1 is ignored for setting; provide a placeholder.
        "OM0\(mode.rawValue);"
    }

    // MARK: - Mode / Data Mode (MD)
    //
    // TS-890 reports "MDx" in Auto Information. We use this as the primary way to enter/exit "USB-DATA".
    // Exact mapping is radio-specific; we treat values as opaque and restore what we observed.
    static func getModeMD() -> String { "MD;" }
    static func setModeMD(_ value: Int) -> String { "MD\(value);" }

    // MARK: - Data Mode (DA)
    //
    // The TS-890 command set supports "data mode" selection separate from base mode on many Kenwood rigs.
    // If the radio rejects these commands, it will respond with `?;` and the app will continue.
    static func getDataMode() -> String { "DA;" }
    static func setDataMode(enabled: Bool) -> String { "DA\(enabled ? 1 : 0);" }

    // MARK: - Noise Reduction / Notch

    enum NoiseReductionMode: Int {
        case off = 0
        case nr1 = 1
        case nr2 = 2

        var label: String {
            switch self {
            case .off: "Off"
            case .nr1: "NR1"
            case .nr2: "NR2"
            }
        }
    }

    static func getNoiseReduction() -> String { "NR;" }
    static func setNoiseReduction(_ mode: NoiseReductionMode) -> String { "NR\(mode.rawValue);" }

    static func getNotch() -> String { "NT;" }
    static func setNotch(enabled: Bool) -> String { "NT\(enabled ? 1 : 0);" }

    // MARK: - Squelch / Meter

    static func getSquelchLevel() -> String { "SQ;" }

    static func setSquelchLevel(_ level: Int) -> String {
        let clamped = max(0, min(level, 255))
        return String(format: "SQ%03d;", clamped)
    }

    static func getSMeter() -> String { "SM;" }

    // MARK: - RF Gain

    static func getRFGain() -> String { "RG;" }

    static func setRFGain(_ value: Int) -> String {
        // TS-890S PC Control command reference guide: 000..255
        let clamped = max(0, min(value, 255))
        return String(format: "RG%03d;", clamped)
    }

    // MARK: - PTT (TX/RX)

    static func pttDown() -> String {
        // "TX" starts transmission. Per command guide: TX0 = SEND/PTT.
        "TX0;"
    }

    static func pttUp() -> String {
        // "RX" returns to receive.
        "RX;"
    }

    // MARK: - VFO Selection / Split

    enum VFO: Int, CaseIterable {
        case a = 0
        case b = 1

        var label: String { self == .a ? "VFO A" : "VFO B" }
    }

    static func getReceiverVFO() -> String { "FR;" }
    static func setReceiverVFO(_ vfo: VFO) -> String { "FR\(vfo.rawValue);" }

    static func getTransmitterVFO() -> String { "FT;" }
    static func setTransmitterVFO(_ vfo: VFO) -> String { "FT\(vfo.rawValue);" }

    // MARK: - RIT / XIT

    static func ritGetState() -> String { "RT;" }
    static func ritSetEnabled(_ enabled: Bool) -> String { "RT\(enabled ? 1 : 0);" }

    static func xitGetState() -> String { "XT;" }
    static func xitSetEnabled(_ enabled: Bool) -> String { "XT\(enabled ? 1 : 0);" }

    static func ritXitClearOffset() -> String { "RC;" }
    static func ritXitGetOffset() -> String { "RF;" }

    static func ritXitStepUp() -> String { "RU;" }
    static func ritXitStepDown() -> String { "RD;" }

    static func ritXitSetOffsetHz(_ hz: Int) -> String {
        // RU is positive; RD is negative. P1 is 5 digits (0..9999).
        let absHz = max(0, min(abs(hz), 9_999))
        if hz >= 0 {
            return String(format: "RU%05d;", absHz)
        } else {
            return String(format: "RD%05d;", absHz)
        }
    }

    // MARK: - RX Filter Low/High Cut and Shift

    static func getReceiveFilterLowCutSettingID() -> String { "SL0;" }
    static func setReceiveFilterLowCutSettingID(_ id: Int) -> String {
        let clamped = max(0, min(id, 99))
        return String(format: "SL0%02d;", clamped)
    }

    static func getReceiveFilterHighCutSettingID() -> String { "SH0;" }
    static func setReceiveFilterHighCutSettingID(_ id: Int) -> String {
        let clamped = max(0, min(id, 999))
        return String(format: "SH0%03d;", clamped)
    }

    static func getReceiveFilterShift() -> String { "IS;" }

    static func setReceiveFilterShiftHz(_ hz: Int) -> String {
        // IS expects sign (+/-/space) and 4 digits. Radio clamps to legal ranges by mode.
        let clamped = max(-9_999, min(hz, 9_999))
        let sign = clamped < 0 ? "-" : "+"
        return String(format: "IS%@%04d;", sign, abs(clamped))
    }

    // MARK: - TX Power

    static func getOutputPower() -> String { "PC;" }
    static func setOutputPowerWatts(_ watts: Int) -> String {
        // HF/50: 5..100. (AM limits differ, but the radio will clamp/reject.)
        let clamped = max(5, min(watts, 100))
        return String(format: "PC%03d;", clamped)
    }

    // MARK: - Antenna Tuner (ATU)

    static func getAntennaTuner() -> String { "AC;" }

    static func setAntennaTuner(txEnabled: Bool) -> String {
        // Per PC Command guide notes: P1 is invalid for setting; enter 1.
        // P3: 0 stop tuning, 1 start tuning.
        return "AC1\(txEnabled ? 1 : 0)0;"
    }

    static func startAntennaTuning() -> String { "AC111;" }
    static func stopAntennaTuning(txEnabled: Bool) -> String { "AC1\(txEnabled ? 1 : 0)0;" }

    // MARK: - Split Offset Setting (kHz)

    static func getSplitOffsetSettingState() -> String { "SP;" }
    static func startSplitOffsetSetting() -> String { "SP1;" }
    static func cancelSplitOffsetSetting() -> String { "SP2;" }

    static func setSplitOffset(plus: Bool, khz: Int) -> String {
        let amount = max(1, min(khz, 9))
        let dir = plus ? 0 : 1
        // Setting 2: SP0 P2 P3;
        return "SP0\(dir)\(amount);"
    }

    // MARK: - Memory Channels

    static func getMemoryMode() -> String { "MV;;" }

    static func setMemoryMode(_ enabled: Bool) -> String {
        // MV expects a trailing ";;" per doc examples.
        return "MV\(enabled ? 1 : 0);;"
    }

    static func getMemoryChannelNumber() -> String { "MN;" }

    static func setMemoryChannelNumber(_ channel: Int) -> String {
        let clamped = max(0, min(channel, 119))
        return String(format: "MN%03d;", clamped)
    }

    static func getMemoryChannelConfiguration(_ channel: Int) -> String {
        let clamped = max(0, min(channel, 119))
        return String(format: "MA0%03d;", clamped)
    }

    static func setMemoryChannelDirectWriteFrequencyHz(_ hz: Int, mode: OperatingMode, fmNarrow: Bool) -> String {
        // MA1 writes to the currently selected memory channel (set with MN).
        // Format: MA1 + P1(11 digits Hz) + P2(mode) + P3(FM narrow) + ;
        let clamped = max(0, min(hz, 99_999_999_999))
        let narrow = fmNarrow ? 1 : 0
        return String(format: "MA1%011d%01d%01d;", clamped, mode.rawValue, narrow)
    }

    static func setMemoryChannelName(_ channel: Int, name: String) -> String {
        // MA2: MA2 + channel(3) + space + name(<=10) + ;
        let clamped = max(0, min(channel, 119))
        let safe = name.replacingOccurrences(of: ";", with: " ")
        let trimmed = String(safe.prefix(10))
        let padded = trimmed.padding(toLength: 10, withPad: " ", startingAt: 0)
        return String(format: "MA2%03d %@;", clamped, padded)
    }

    // MARK: - Extended Menu (EX) — EQ, NB level, NR level, TX bandwidth, etc.
    //
    // TS-890S format: EX + 3-digit menu number + value
    // Query:  EX[nnn];
    // Set:    EX[nnn][value];   (value format varies: signed dB uses +/-nn, others plain integer)
    //
    // Known EQ menu numbers (verify against your firmware with EX query):
    //   TX EQ: 030 = Low gain, 031 = Mid gain, 032 = High gain  (-20…+10 dB)
    //   RX EQ: 060 = Low gain, 061 = Mid gain, 062 = High gain  (-20…+10 dB)

    static func getMenuValue(_ menuNumber: Int) -> String {
        String(format: "EX%03d;", menuNumber)
    }

    /// Set a plain-integer menu value (e.g. NB level 0-10, TX bandwidth, etc.)
    static func setMenuValue(_ menuNumber: Int, value: Int) -> String {
        String(format: "EX%03d%d;", menuNumber, value)
    }

    /// Set a signed dB EQ gain (−20…+10). Uses explicit +/- sign per TS-890S protocol.
    static func setEQGain(_ menuNumber: Int, dB: Int) -> String {
        let clamped = max(-20, min(dB, 10))
        let sign = clamped >= 0 ? "+" : "-"
        return String(format: "EX%03d%@%02d;", menuNumber, sign, abs(clamped))
    }

    // MARK: - TX EQ convenience (menu 030–032)
    static func getTXEQLow() -> String    { getMenuValue(30) }
    static func getTXEQMid() -> String    { getMenuValue(31) }
    static func getTXEQHigh() -> String   { getMenuValue(32) }
    static func setTXEQLow(_ dB: Int) -> String   { setEQGain(30, dB: dB) }
    static func setTXEQMid(_ dB: Int) -> String   { setEQGain(31, dB: dB) }
    static func setTXEQHigh(_ dB: Int) -> String  { setEQGain(32, dB: dB) }

    // MARK: - RX EQ convenience (menu 060–062)
    static func getRXEQLow() -> String    { getMenuValue(60) }
    static func getRXEQMid() -> String    { getMenuValue(61) }
    static func getRXEQHigh() -> String   { getMenuValue(62) }
    static func setRXEQLow(_ dB: Int) -> String   { setEQGain(60, dB: dB) }
    static func setRXEQMid(_ dB: Int) -> String   { setEQGain(61, dB: dB) }
    static func setRXEQHigh(_ dB: Int) -> String  { setEQGain(62, dB: dB) }
}
