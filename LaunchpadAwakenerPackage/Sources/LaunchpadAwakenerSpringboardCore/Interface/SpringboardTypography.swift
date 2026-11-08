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
    /// An open folder's title: Light 28 (`-[ECSBGroupLayer initWithGroup:groupPager:layoutRTL:]`).
    nonisolated(unsafe) static let folderTitleFont = systemFont(size: 28, weight: lightWeight)

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

    /// In the Dock's own language: the one its bundle — the host's resource bundle — picks for the user.
    private static var currentTranslation: (search: String, noResults: String) {
        translation(forLocalizations: SpringboardLocalization.preferredLocalizations)
    }

    /// The words for the first of `localizations` that 15 had them in; English when it had none of them.
    static func translation(forLocalizations localizations: [String]) -> (search: String, noResults: String) {
        SpringboardLocalization.firstTranslation(in: translations, forLocalizations: localizations) ?? translations["en"]!
    }
}

/// The languages the springboard speaks: the Dock's, as the host's resource bundle — the Dock's bundle —
/// would pick them for the user. English without one.
///
/// Worked out from the bundle's own list instead of asked of it: a bundle other than the main one follows
/// the main bundle's language, and the standalone app's main bundle has only English, so there the Dock's
/// bundle answered English on a Chinese system. Inside the Dock both ways give the same answer.
enum SpringboardLocalization {
    static var preferredLocalizations: [String] {
        preferredLocalizations(of: SpringboardHostSystem.host.resourceBundle)
    }

    static func preferredLocalizations(of resourceBundle: Bundle?, forPreferences preferences: [String] = Locale.preferredLanguages) -> [String] {
        guard let resourceBundle else { return [] }
        return Bundle.preferredLocalizations(from: resourceBundle.localizations, forPreferences: preferences)
    }

    /// `key` from the bundle's `Localizable` strings in those languages; `defaultValue` without them.
    static func string(forKey key: String, defaultValue: String, in resourceBundle: Bundle?, forPreferences preferences: [String] = Locale.preferredLanguages) -> String {
        guard let resourceBundle else { return defaultValue }
        if #available(macOS 15.4, *) {
            let languages = preferredLocalizations(of: resourceBundle, forPreferences: preferences).map(Locale.Language.init(identifier:))
            return resourceBundle.localizedString(forKey: key, value: defaultValue, table: nil, localizations: languages)
        }
        return resourceBundle.localizedString(forKey: key, value: defaultValue, table: nil)
    }

    /// The entry for the first of `localizations` in `translations`, keyed the way the Dock's `.lproj`
    /// folders are named (`zh_CN`, `pt_BR`), falling back from a region to its language (`fr_CA` to `fr`).
    static func firstTranslation<Translation>(in translations: [String: Translation], forLocalizations localizations: [String]) -> Translation? {
        for localization in localizations {
            let normalizedLocalization = localization.replacingOccurrences(of: "-", with: "_")
            if let translation = translations[normalizedLocalization] ?? translations[String(normalizedLocalization.prefix(2))] {
                return translation
            }
        }
        return nil
    }
}

/// The words of 15's confirmation for deleting an application. 27's Dock.app no longer carries them, so
/// they are `Delete`, `Cancel` and `Are you sure you want to delete the application “%@”?` from every
/// `Localizable.strings` of macOS 15.5's Dock.app, verbatim.
enum SpringboardDeletionStrings {
    private static let translations: [String: (delete: String, cancel: String, message: String)] = [
        "ar": ("حذف", "إلغاء", "هل أنت متأكد من رغبتك في حذف التطبيق \"%@\"؟"),
        "ca": ("Elimina", "Cancel·la", "Confirmes que vols eliminar l’app %@?"),
        "cs": ("Smazat", "Zrušit", "Určitě chcete aplikaci „%@“ smazat?"),
        "da": ("Slet", "Annuller", "Er du sikker på, at du vil slette appen “%@”?"),
        "de": ("Löschen", "Abbrechen", "Soll „%@“ wirklich gelöscht werden?"),
        "el": ("Διαγραφή", "Ακύρωση", "Θέλετε σίγουρα να διαγράψετε την εφαρμογή «%@»;"),
        "en": ("Delete", "Cancel", "Are you sure you want to delete the application “%@”?"),
        "en_AU": ("Delete", "Cancel", "Are you sure you want to delete the application “%@”?"),
        "en_GB": ("Delete", "Cancel", "Are you sure you want to delete the application “%@”?"),
        "es": ("Eliminar", "Cancelar", "¿Seguro que quieres eliminar la aplicación %@?"),
        "es_419": ("Eliminar", "Cancelar", "¿Quieres eliminar la aplicación “%@”?"),
        "fi": ("Poista", "Kumoa", "Poistetaanko %@?"),
        "fr": ("Supprimer", "Annuler", "Voulez-vous vraiment supprimer l’application « %@ » ?"),
        "fr_CA": ("Supprimer", "Annuler", "Voulez-vous vraiment supprimer l’application « %@ »?"),
        "he": ("מחיקה", "ביטול", "האם ברצונך למחוק את היישום ״⁨%@⁩״?"),
        "hi": ("डिलीट करें", "रद्द करें", "क्या आप निश्चित हैं कि आप ऐप्लिकेशन “%@” को डिलीट करना चाहते हैं?"),
        "hr": ("Obriši", "Odustani", "Sigurno želite obrisati aplikaciju “%@”?"),
        "hu": ("Törlés", "Mégsem", "Biztosan törli a(z) „%@” alkalmazást?"),
        "id": ("Hapus", "Batalkan", "Apakah Anda yakin ingin menghapus aplikasi “%@”?"),
        "it": ("Elimina", "Annulla", "Confermi di volere eliminare l’applicazione “%@”?"),
        "ja": ("削除", "キャンセル", "アプリケーション“%@”を削除してもよろしいですか?"),
        "ko": ("삭제", "취소", "‘%@’ 응용 프로그램을 삭제하겠습니까?"),
        "ms": ("Padam", "Batal", "Adakah anda pasti mahu memadamkan aplikasi “%@”?"),
        "nl": ("Verwijder", "Annuleer", "Weet je zeker dat je de app %@ wilt verwijderen?"),
        "no": ("Slett", "Avbryt", "Er du sikker på at du vil slette appen «%@»?"),
        "pl": ("Usuń", "Anuluj", "Czy na pewno chcesz usunąć aplikację „%@”?"),
        "pt_BR": ("Apagar", "Cancelar", "Tem certeza de que deseja apagar o aplicativo “%@”?"),
        "pt_PT": ("Apagar", "Cancelar", "Tem a certeza de que pretende apagar a aplicação “%@”?"),
        "ro": ("Șterge", "Renunță", "Sigur doriți să ștergeți aplicația „%@”?"),
        "ru": ("Удалить", "Отменить", "Вы действительно хотите удалить программу «%@»?"),
        "sk": ("Vymazať", "Zrušiť", "Naozaj chcete vymazať aplikáciu „%@“?"),
        "sl": ("Izbriši", "Prekliči", "Ste prepričani, da želite izbrisati aplikacijo »%@«?"),
        "sv": ("Radera", "Avbryt", "Är du säker på att du vill radera appen ”%@”?"),
        "th": ("ลบ", "ยกเลิก", "คุณแน่ใจหรือไม่ว่าคุณต้องการลบแอปพลิเคชัน “%@”"),
        "tr": ("Sil", "Vazgeç", "“%@” uygulamasını silmek istediğinizden emin misiniz?"),
        "uk": ("Видалити", "Скасувати", "Справді видалити програму «%@»?"),
        "vi": ("Xóa", "Hủy", "Bạn có chắc chắn muốn xóa ứng dụng “%@” không?"),
        "zh_CN": ("删除", "取消", "确定要删除应用程序“%@”吗？"),
        "zh_HK": ("刪除", "取消", "確定要刪除應用程式「%@」嗎？"),
        "zh_TW": ("刪除", "取消", "確定要刪除應用程式「%@」嗎？"),
    ]

    static var delete: String { currentTranslation.delete }
    static var cancel: String { currentTranslation.cancel }

    static func message(forApplicationNamed applicationName: String) -> String {
        currentTranslation.message.replacingOccurrences(of: "%@", with: applicationName)
    }

    /// In the Dock's own language, as ``SpringboardStrings`` are.
    private static var currentTranslation: (delete: String, cancel: String, message: String) {
        SpringboardLocalization.firstTranslation(in: translations, forLocalizations: SpringboardLocalization.preferredLocalizations) ?? translations["en"]!
    }
}
