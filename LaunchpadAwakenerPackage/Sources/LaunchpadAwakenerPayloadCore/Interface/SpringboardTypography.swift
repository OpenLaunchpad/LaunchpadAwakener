import CoreGraphics
import CoreText
import Foundation

/// The fonts of macOS 15's Launchpad, built with Core Text — the Dock does not load AppKit.
enum SpringboardTypography {
    /// `.SFNS-Medium`, UI font type 105 in 15's `-[ECSBEnvironment init]`.
    static let mediumWeight: CGFloat = 0.23
    /// `.SFNS-Light`, UI font type 103.
    static let lightWeight: CGFloat = -0.4

    // Core Text fonts are immutable and safe to share between threads; CoreText just does not say
    // so to Swift.

    /// Icon titles: Medium 13 with monospaced digits.
    nonisolated(unsafe) static let labelFont = systemFont(size: 13, weight: mediumWeight, hasMonospacedDigits: true)
    /// The search field: Light 16.
    nonisolated(unsafe) static let searchFont = systemFont(size: 16, weight: lightWeight)
    /// "No Results": Light 40.
    nonisolated(unsafe) static let noResultsFont = systemFont(size: 40, weight: lightWeight)

    static func systemFont(size: CGFloat, weight: CGFloat, hasMonospacedDigits: Bool = false) -> CTFont {
        let baseFont = CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        var attributes: [CFString: Any] = [kCTFontTraitsAttribute: [kCTFontWeightTrait: weight]]
        if hasMonospacedDigits {
            attributes[kCTFontFeatureSettingsAttribute] = [
                [kCTFontFeatureTypeIdentifierKey: 6, kCTFontFeatureSelectorIdentifierKey: 0],
            ]
        }
        let descriptor = CTFontDescriptorCreateCopyWithAttributes(CTFontCopyFontDescriptor(baseFont), attributes as CFDictionary)
        return CTFontCreateWithFontDescriptor(descriptor, size, nil)
    }

    /// `ceil(ascent + descent + leading)`, as 15's `sub_10000CBE8` measured a line.
    static func lineHeight(of font: CTFont) -> CGFloat {
        ceil(CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font))
    }

    static func width(of string: String, in font: CTFont) -> CGFloat {
        let attributedString = NSAttributedString(string: string, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        let line = CTLineCreateWithAttributedString(attributedString)
        return ceil(CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
    }
}

/// The two strings macOS 27's Dock no longer carries, as macOS 15.5's Dock translated them.
enum SpringboardStrings {
    /// `Search` and `No Results` from every `Localizable.strings` of macOS 15.5's Dock.app, verbatim.
    private static let translations: [String: (search: String, noResults: String)] = [
        "ar": ("بحث", "لا توجد نتائج"),
        "ca": ("Cerca", "Cap resultat"),
        "cs": ("Hledat", "Žádné výsledky"),
        "da": ("Søg", "Ingen resultater"),
        "de": ("Suchen", "Keine Ergebnisse"),
        "el": ("Αναζήτηση", "Δεν υπάρχουν αποτελέσματα"),
        "en": ("Search", "No Results"),
        "en_AU": ("Search", "No Results"),
        "en_GB": ("Search", "No Results"),
        "es": ("Buscar", "Sin resultados"),
        "es_419": ("Búsqueda", "Ningún resultado"),
        "fi": ("Etsi", "Ei tuloksia"),
        "fr": ("Rechercher", "Aucun résultat"),
        "fr_CA": ("Rechercher", "Aucun résultat"),
        "he": ("חיפוש", "אין תוצאות"),
        "hi": ("खोजें", "कोई परिणाम नहीं"),
        "hr": ("Traži", "Bez rezultata"),
        "hu": ("Keresés", "Nincs találat"),
        "id": ("Cari", "Tidak Ada Hasil"),
        "it": ("Cerca", "Nessun risultato"),
        "ja": ("検索", "結果なし"),
        "ko": ("검색", "결과 없음"),
        "ms": ("Cari", "Tiada Hasil"),
        "nl": ("Zoek", "Geen resultaten"),
        "no": ("Søk", "Ingen treff"),
        "pl": ("Szukaj", "Brak wyników"),
        "pt_BR": ("Buscar", "Nenhum Resultado"),
        "pt_PT": ("Pesquisa", "Nenhum resultado"),
        "ro": ("Căutare", "Niciun rezultat"),
        "ru": ("Поиск", "Нет результатов"),
        "sk": ("Vyhľadať", "Žiadne výsledky"),
        "sl": ("Iskanje", "Ni rezultatov"),
        "sv": ("Sök", "Inga träffar"),
        "th": ("ค้นหา", "ไม่มีผลการค้นหา"),
        "tr": ("Ara", "Hiç Sonuç Yok"),
        "uk": ("Пошук", "Немає результатів"),
        "vi": ("Tìm kiếm", "Không có kết quả"),
        "zh_CN": ("搜索", "无结果"),
        "zh_HK": ("搜尋", "沒有結果"),
        "zh_TW": ("搜尋", "沒有結果"),
    ]

    static var search: String { currentTranslation.search }
    static var noResults: String { currentTranslation.noResults }

    /// The Dock's own language, which `Bundle.main` reports inside the Dock.
    private static var currentTranslation: (search: String, noResults: String) {
        for localization in Bundle.main.preferredLocalizations {
            let normalizedLocalization = localization.replacingOccurrences(of: "-", with: "_")
            if let translation = translations[normalizedLocalization] ?? translations[String(normalizedLocalization.prefix(2))] {
                return translation
            }
        }
        return translations["en"]!
    }
}
