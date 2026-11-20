import Foundation

enum AppLanguage: String, CaseIterable, Identifiable, Codable {
    case en, tr, es, fr, de, it, pt, ja, zh, ko, ru, ar

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .en: return "English"
        case .tr: return "Türkçe"
        case .es: return "Español"
        case .fr: return "Français"
        case .de: return "Deutsch"
        case .it: return "Italiano"
        case .pt: return "Português"
        case .ja: return "日本語"
        case .zh: return "中文"
        case .ko: return "한국어"
        case .ru: return "Русский"
        case .ar: return "العربية"
        }
    }

    var isRightToLeft: Bool { self == .ar }
}

enum L10nKey: String, CaseIterable {
    case statusTitle
    case settingsTitle
    case tabGeneral
    case tabDelete
    case settingsLanguage
    case settingsSecurity
    case securityNormal
    case securitySensitive
    case securityInfo
    case settingsAutoDelete24h
    case autoDelete24hInfo
    case settingsLogin
    case settingsLoginApproval
    case settingsLoginError
    case settingsLimit
    case settingsShortcut
    case deleteRangeHeader
    case rangeToday
    case rangeYesterday
    case rangeLastWeek
    case rangeAllTime
    case deletePinnedNote
    case deleteButton
    case deleteConfirmTitle
    case deleteEmptyHint
    case searchPlaceholder
    case searchButton
    case historyEmpty
    case searchEmpty
    case historyImage
    case historyOptions
    case settingsOpen
    case deleteHistoryMenu
    case appQuit
    case pinItem
    case unpinItem
    case removeItem
    case cancel
    case deleteAction
    case pinnedLabel
}

enum L10n {
    static func string(_ key: L10nKey, _ lang: AppLanguage) -> String {
        if let value = translations[key]?[lang] {
            return value
        }
        return translations[key]?[.en] ?? key.rawValue
    }

    static func itemCount(_ count: Int, _ lang: AppLanguage) -> String {
        switch lang {
        case .en: return count == 1 ? "1 item" : "\(count) items"
        case .tr: return "\(count) öğe"
        case .es: return count == 1 ? "1 elemento" : "\(count) elementos"
        case .fr: return count <= 1 ? "\(count) élément" : "\(count) éléments"
        case .de: return count == 1 ? "1 Element" : "\(count) Elemente"
        case .it: return count == 1 ? "1 elemento" : "\(count) elementi"
        case .pt: return count == 1 ? "1 item" : "\(count) itens"
        case .ja: return "\(count) 件"
        case .zh: return "\(count) 项"
        case .ko: return "\(count)개 항목"
        case .ru: return russianItems(count)
        case .ar: return "\(count) عناصر"
        }
    }

    static func deleteConfirmMessage(_ count: Int, _ lang: AppLanguage) -> String {
        switch lang {
        case .en: return "This will permanently delete \(count) unpinned \(count == 1 ? "item" : "items"). Pinned items remain safe."
        case .tr: return "Sabitlenmemiş \(count) öğe kalıcı olarak silinecek. Sabitlenen öğeler korunur."
        case .es: return "Se eliminarán permanentemente \(count) elementos no fijados. Los fijados se conservarán."
        case .fr: return "\(count) éléments non épinglés seront supprimés définitivement. Les éléments épinglés restent protégés."
        case .de: return "\(count) nicht angeheftete Elemente werden dauerhaft gelöscht. Angeheftete Elemente bleiben geschützt."
        case .it: return "Verranno eliminati definitivamente \(count) elementi non fissati. Quelli fissati restano al sicuro."
        case .pt: return "\(count) itens não fixados serão excluídos permanentemente. Itens fixados permanecem protegidos."
        case .ja: return "ピン留めされていない\(count)件の項目を完全に削除します。ピン留めされた項目は保護されます。"
        case .zh: return "将永久删除 \(count) 个未固定的项目。已固定的项目将保留。"
        case .ko: return "고정되지 않은 \(count)개 항목이 영구 삭제됩니다. 고정된 항목은 유지됩니다."
        case .ru: return "Будет безвозвратно удалено \(count) незакреплённых элементов. Закреплённые сохранятся."
        case .ar: return "سيتم حذف \(count) من العناصر غير المثبتة نهائيًا. ستبقى العناصر المثبتة محفوظة."
        }
    }

    static func deleteDoneFeedback(_ count: Int, _ lang: AppLanguage) -> String {
        switch lang {
        case .en: return count == 0 ? string(.deleteEmptyHint, lang) : "Deleted \(count) \(count == 1 ? "item" : "items")."
        case .tr: return count == 0 ? string(.deleteEmptyHint, lang) : "\(count) öğe silindi."
        case .es: return count == 0 ? string(.deleteEmptyHint, lang) : "Se eliminaron \(count) elementos."
        case .fr: return count == 0 ? string(.deleteEmptyHint, lang) : "\(count) éléments supprimés."
        case .de: return count == 0 ? string(.deleteEmptyHint, lang) : "\(count) Elemente gelöscht."
        case .it: return count == 0 ? string(.deleteEmptyHint, lang) : "\(count) elementi eliminati."
        case .pt: return count == 0 ? string(.deleteEmptyHint, lang) : "\(count) itens excluídos."
        case .ja: return count == 0 ? string(.deleteEmptyHint, lang) : "\(count) 件削除しました。"
        case .zh: return count == 0 ? string(.deleteEmptyHint, lang) : "已删除 \(count) 项。"
        case .ko: return count == 0 ? string(.deleteEmptyHint, lang) : "\(count)개 항목을 삭제했습니다."
        case .ru: return count == 0 ? string(.deleteEmptyHint, lang) : "Удалено элементов: \(count)."
        case .ar: return count == 0 ? string(.deleteEmptyHint, lang) : "تم حذف \(count) عناصر."
        }
    }

    private static func russianItems(_ count: Int) -> String {
        let mod100 = count % 100
        let mod10 = count % 10
        if mod100 >= 11 && mod100 <= 14 { return "\(count) элементов" }
        switch mod10 {
        case 1: return "\(count) элемент"
        case 2, 3, 4: return "\(count) элемента"
        default: return "\(count) элементов"
        }
    }

    private static let translations: [L10nKey: [AppLanguage: String]] = [
        .statusTitle: [
            .en: "Kastor Clipboard History",
            .tr: "Kastor Pano Geçmişi",
            .es: "Historial de Portapapeles Kastor",
            .fr: "Historique du presse-papiers Kastor",
            .de: "Kastor Zwischenablageverlauf",
            .it: "Cronologia Appunti Kastor",
            .pt: "Histórico da Área de Transferência Kastor",
            .ja: "Kastor クリップボード履歴",
            .zh: "Kastor 剪贴板历史",
            .ko: "Kastor 클립보드 기록",
            .ru: "История буфера обмена Kastor",
            .ar: "سجل الحافظة Kastor",
        ],
        .settingsTitle: [
            .en: "Kastor Settings",
            .tr: "Kastor Ayarları",
            .es: "Ajustes de Kastor",
            .fr: "Réglages de Kastor",
            .de: "Kastor-Einstellungen",
            .it: "Impostazioni di Kastor",
            .pt: "Ajustes do Kastor",
            .ja: "Kastor 設定",
            .zh: "Kastor 设置",
            .ko: "Kastor 설정",
            .ru: "Настройки Kastor",
            .ar: "إعدادات Kastor",
        ],
        .tabGeneral: [
            .en: "General",
            .tr: "Genel",
            .es: "General",
            .fr: "Général",
            .de: "Allgemein",
            .it: "Generali",
            .pt: "Geral",
            .ja: "一般",
            .zh: "通用",
            .ko: "일반",
            .ru: "Основные",
            .ar: "عام",
        ],
        .tabDelete: [
            .en: "Delete",
            .tr: "Silme",
            .es: "Eliminar",
            .fr: "Suppression",
            .de: "Löschen",
            .it: "Elimina",
            .pt: "Excluir",
            .ja: "削除",
            .zh: "删除",
            .ko: "삭제",
            .ru: "Удаление",
            .ar: "حذف",
        ],
        .settingsLanguage: [
            .en: "Language",
            .tr: "Dil",
            .es: "Idioma",
            .fr: "Langue",
            .de: "Sprache",
            .it: "Lingua",
            .pt: "Idioma",
            .ja: "言語",
            .zh: "语言",
            .ko: "언어",
            .ru: "Язык",
            .ar: "اللغة",
        ],
        .settingsSecurity: [
            .en: "Security",
            .tr: "Güvenlik",
            .es: "Seguridad",
            .fr: "Sécurité",
            .de: "Sicherheit",
            .it: "Sicurezza",
            .pt: "Segurança",
            .ja: "セキュリティ",
            .zh: "安全模式",
            .ko: "보안",
            .ru: "Безопасность",
            .ar: "الأمان",
        ],
        .securityNormal: [
            .en: "Normal",
            .tr: "Normal",
            .es: "Normal",
            .fr: "Normal",
            .de: "Normal",
            .it: "Normale",
            .pt: "Normal",
            .ja: "通常",
            .zh: "普通",
            .ko: "일반",
            .ru: "Обычный",
            .ar: "عادي",
        ],
        .securitySensitive: [
            .en: "Sensitive",
            .tr: "Hassas",
            .es: "Sensible",
            .fr: "Sensible",
            .de: "Sensibel",
            .it: "Sensibile",
            .pt: "Sensível",
            .ja: "厳格",
            .zh: "敏感保护",
            .ko: "민감 보호",
            .ru: "Строгий",
            .ar: "حساس",
        ],
        .securityInfo: [
            .en: "In Sensitive mode, secret tokens (such as github_pat_, API keys, private keys, JWTs), password managers, concealed/transient items, and file:// URLs are blocked from capture and storage. Switch to Normal to allow copying and saving these items.",
            .tr: "Hassas modda gizli tokenlar (github_pat_, API anahtarları, özel anahtarlar, JWT), şifre yöneticileri, gizli/geçici pano verileri ve file:// bağlantıları engellenir. Normal moda geçerseniz bu içerikler kopyalanıp saklanabilir.",
            .es: "En modo Sensible, se bloquean tokens secretos (como github_pat_, claves API, claves privadas, JWT), gestores de contraseñas, datos ocultos o transitorios y URLs file://. En modo Normal, estas restricciones se desactivan.",
            .fr: "En mode Sensible, les jetons secrets (github_pat_, clés API, clés privées, JWT), gestionnaires de mots de passe, éléments masqués/éphémères et URL file:// sont bloqués. En mode Normal, ces restrictions sont désactivées.",
            .de: "Im Modus Sensibel werden geheime Tokens (wie github_pat_, API-Schlüssel, private Schlüssel, JWTs), Passwortmanager, verdeckte/flüchtige Inhalte und file://-URLs blockiert. Im Modus Normal sind diese Filter deaktiviert.",
            .it: "In modalità Sensibile, token segreti (github_pat_, chiavi API, chiavi private, JWT), gestori di password, dati nascosti/transitori e URL file:// vengono bloccati. In modalità Normale queste restrizioni sono disattivate.",
            .pt: "No modo Sensível, tokens secretos (github_pat_, chaves de API, chaves privadas, JWTs), gerenciadores de senhas, dados ocultos/transitórios e URLs file:// são bloqueados. No modo Normal, essas restrições ficam desativadas.",
            .ja: "厳格モードでは、シークレットトークン（github_pat_、APIキー、秘密鍵、JWTなど）、パスワード管理アプリ、秘匿・一時クリップボード項目、file:// URLの保存をブロックします。通常モードではこれらを許可します。",
            .zh: "在敏感保护模式下，会阻止捕获和保存密钥令牌（如 github_pat_、API 密钥、私钥、JWT）、密码管理器内容、隐藏/临时剪贴板数据以及 file:// 链接。切换到普通模式即可允许复制和保存。",
            .ko: "민감 보호 모드에서는 시크릿 토큰(github_pat_, API 키, 개인 키, JWT), 비밀번호 관리자, 숨김/임시 클립보드 항목 및 file:// URL 저장이 차단됩니다. 일반 모드로 전환하면 이러한 제한이 해제됩니다.",
            .ru: "В строгом режиме блокируются секретные токены (github_pat_, API-ключи, приватные ключи, JWT), менеджеры паролей, скрытые/временные данные и ссылки file://. В обычном режиме эти ограничения отключены.",
            .ar: "في الوضع الحساس، يتم حظر الرموز السرية (مثل github_pat_ ومفاتيح API والمفاتيح الخاصة وJWT) ومديري كلمات المرور والعناصر المخفية أو المؤقتة وروابط file://. يؤدي التبديل إلى الوضع العادي إلى السماح بحفظها.",
        ],
        .settingsAutoDelete24h: [
            .en: "Auto-delete after 24 hours",
            .tr: "24 saat sonra otomatik sil",
            .es: "Eliminar tras 24 horas",
            .fr: "Supprimer après 24 heures",
            .de: "Nach 24 Stunden löschen",
            .it: "Elimina dopo 24 ore",
            .pt: "Excluir após 24 horas",
            .ja: "24時間後に自動削除",
            .zh: "24 小时后自动删除",
            .ko: "24시간 후 자동 삭제",
            .ru: "Удалять через 24 часа",
            .ar: "الحذف التلقائي بعد 24 ساعة",
        ],
        .autoDelete24hInfo: [
            .en: "When enabled, unpinned clipboard items are automatically deleted every 24 hours to limit RAM and storage growth. Payloads are stored encrypted on disk and loaded only when needed. Pinned items are never auto-deleted.",
            .tr: "Açık olduğunda, RAM ve bellek tüketiminin artmasını önlemek için sabitlenmemiş öğeler 24 saatte bir otomatik silinir. Öğeler diskte şifreli tutulur ve yalnızca gerektiğinde yüklenir. Sabitlenenler silinmez.",
            .es: "Si se activa, los elementos no fijados se eliminan cada 24 horas para limitar el uso de RAM y almacenamiento. Los fijados nunca se eliminan automáticamente.",
            .fr: "Lorsqu'il est activé, les éléments non épinglés sont supprimés toutes les 24 heures pour limiter l'usage de la RAM. Les éléments épinglés restent protégés.",
            .de: "Wenn aktiviert, werden nicht angeheftete Einträge alle 24 Stunden automatisch gelöscht, um den RAM-Verbrauch zu begrenzen. Angeheftete Einträge bleiben erhalten.",
            .it: "Se attivo, gli elementi non fissati vengono eliminati automaticamente ogni 24 ore per limitare il consumo di RAM. Gli elementi fissati non vengono mai eliminati.",
            .pt: "Quando ativado, itens não fixados são excluídos automaticamente a cada 24 horas para limitar o uso de RAM. Itens fixados nunca são apagados automaticamente.",
            .ja: "有効にすると、RAM消費の増加を抑えるため、ピン留めされていない項目が24時間ごとに自動削除されます。ピン留めされた項目は保護されます。",
            .zh: "启用后，为限制内存增长，未固定的条目将在 24 小时后自动删除。完整内容仅在需要时从加密磁盘按需加载。已固定的条目不会被自动删除。",
            .ko: "활성화하면 RAM 사용량 증가를 제한하기 위해 고정되지 않은 항목이 24시간마다 자동 삭제됩니다. 고정된 항목은 자동 삭제되지 않습니다.",
            .ru: "При включении незакреплённые записи автоматически удаляются через 24 часа для ограничения расхода RAM. Закреплённые записи не удаляются.",
            .ar: "عند التفعيل، يتم حذف العناصر غير المثبتة تلقائيًا كل 24 ساعة للحد من استهلاك الذاكرة RAM. تبقى العناصر المثبتة محفوظة دائمًا.",
        ],
        .settingsLogin: [
            .en: "Launch at login",
            .tr: "Oturum açınca başlat",
            .es: "Abrir al iniciar sesión",
            .fr: "Lancer à l'ouverture de session",
            .de: "Bei der Anmeldung starten",
            .it: "Avvia al login",
            .pt: "Iniciar no login",
            .ja: "ログイン時に起動",
            .zh: "登录时启动",
            .ko: "로그인 시 시작",
            .ru: "Запускать при входе",
            .ar: "التشغيل عند تسجيل الدخول",
        ],
        .settingsLoginApproval: [
            .en: "Allow Kastor in System Settings → Login Items & Extensions.",
            .tr: "Sistem Ayarları → Giriş Öğeleri ve Genişletmeler bölümünde Kastor’a izin verin.",
            .es: "Permite Kastor en Ajustes del Sistema → Ítems de inicio y extensiones.",
            .fr: "Autorisez Kastor dans Réglages Système → Ouverture et extensions.",
            .de: "Erlaube Kastor unter Systemeinstellungen → Anmeldeobjekte & Erweiterungen.",
            .it: "Consenti Kastor in Impostazioni di Sistema → Elementi login ed estensioni.",
            .pt: "Permita o Kastor em Ajustes do Sistema → Itens de Início e Extensões.",
            .ja: "システム設定 → ログイン項目と機能拡張で Kastor を許可してください。",
            .zh: "请在“系统设置 → 登录项与扩展”中允许 Kastor。",
            .ko: "시스템 설정 → 로그인 항목 및 확장 프로그램에서 Kastor를 허용하세요.",
            .ru: "Разрешите Kastor в Системных настройках → Объекты входа и расширения.",
            .ar: "اسمح لتطبيق Kastor في إعدادات النظام ← عناصر تسجيل الدخول والملحقات.",
        ],
        .settingsLoginError: [
            .en: "The login setting could not be changed.",
            .tr: "Başlangıç ayarı değiştirilemedi.",
            .es: "No se pudo cambiar el ajuste de inicio.",
            .fr: "Impossible de modifier le lancement à l'ouverture.",
            .de: "Die Anmeldeeinstellung konnte nicht geändert werden.",
            .it: "Impossibile modificare l'impostazione di avvio.",
            .pt: "Não foi possível alterar a configuração de início.",
            .ja: "ログイン設定を変更できませんでした。",
            .zh: "无法更改登录启动设置。",
            .ko: "로그인 설정을 변경할 수 없습니다.",
            .ru: "Не удалось изменить параметр автозапуска.",
            .ar: "تعذر تغيير إعداد التشغيل عند تسجيل الدخول.",
        ],
        .settingsLimit: [
            .en: "History size",
            .tr: "Geçmiş boyutu",
            .es: "Tamaño del historial",
            .fr: "Taille de l'historique",
            .de: "Verlaufsgröße",
            .it: "Dimensione cronologia",
            .pt: "Tamanho do histórico",
            .ja: "履歴の上限",
            .zh: "历史记录上限",
            .ko: "기록 보관 수",
            .ru: "Размер истории",
            .ar: "حجم السجل",
        ],
        .settingsShortcut: [
            .en: "Open clipboard",
            .tr: "Panoyu aç",
            .es: "Abrir portapapeles",
            .fr: "Ouvrir le presse-papiers",
            .de: "Zwischenablage öffnen",
            .it: "Apri appunti",
            .pt: "Abrir área de transferência",
            .ja: "クリップボードを開く",
            .zh: "打开剪贴板",
            .ko: "클립보드 열기",
            .ru: "Открыть буфер обмена",
            .ar: "فتح الحافظة",
        ],
        .deleteRangeHeader: [
            .en: "Delete history from",
            .tr: "Geçmişi sil",
            .es: "Eliminar historial de",
            .fr: "Supprimer l'historique de",
            .de: "Verlauf löschen für",
            .it: "Elimina cronologia da",
            .pt: "Excluir histórico de",
            .ja: "履歴を削除する期間",
            .zh: "删除指定时间段的历史",
            .ko: "기록 삭제 범위",
            .ru: "Удалить историю за период",
            .ar: "حذف السجل من",
        ],
        .rangeToday: [
            .en: "Today",
            .tr: "Bugün",
            .es: "Hoy",
            .fr: "Aujourd'hui",
            .de: "Heute",
            .it: "Oggi",
            .pt: "Hoje",
            .ja: "今日",
            .zh: "今天",
            .ko: "오늘",
            .ru: "Сегодня",
            .ar: "اليوم",
        ],
        .rangeYesterday: [
            .en: "Yesterday",
            .tr: "Dün",
            .es: "Ayer",
            .fr: "Hier",
            .de: "Gestern",
            .it: "Ieri",
            .pt: "Ontem",
            .ja: "昨日",
            .zh: "昨天",
            .ko: "어제",
            .ru: "Вчера",
            .ar: "أمس",
        ],
        .rangeLastWeek: [
            .en: "Last week",
            .tr: "Son hafta",
            .es: "Última semana",
            .fr: "Dernière semaine",
            .de: "Letzte Woche",
            .it: "Ultima settimana",
            .pt: "Última semana",
            .ja: "先週",
            .zh: "最近一周",
            .ko: "지난주",
            .ru: "Последняя неделя",
            .ar: "الأسبوع الماضي",
        ],
        .rangeAllTime: [
            .en: "All time",
            .tr: "Tüm zamanlar",
            .es: "Todo el historial",
            .fr: "Tout l'historique",
            .de: "Gesamte Zeit",
            .it: "Tutto",
            .pt: "Todo o período",
            .ja: "全期間",
            .zh: "所有时间",
            .ko: "전체 기간",
            .ru: "За всё время",
            .ar: "كل الوقت",
        ],
        .deletePinnedNote: [
            .en: "Pinned items are protected from automatic and range deletion.",
            .tr: "Sabitlenen öğeler otomatik ve toplu silme işlemlerinden korunur.",
            .es: "Los elementos fijados están protegidos contra el borrado automático y masivo.",
            .fr: "Les éléments épinglés sont protégés contre la suppression automatique et groupée.",
            .de: "Angeheftete Elemente sind vor automatischem und Bereichslöschen geschützt.",
            .it: "Gli elementi fissati sono protetti dall'eliminazione automatica e per intervallo.",
            .pt: "Itens fixados são protegidos contra exclusão automática e em lote.",
            .ja: "ピン留めされた項目は自動削除および一括削除から保護されます。",
            .zh: "已固定的项目受保护，不会在自动清理或批量删除中被移除。",
            .ko: "고정된 항목은 자동 삭제 및 일괄 삭제에서 보호됩니다.",
            .ru: "Закреплённые элементы защищены от автоматического и массового удаления.",
            .ar: "العناصر المثبتة محمية من الحذف التلقائي وحذف النطاق.",
        ],
        .deleteButton: [
            .en: "Delete History",
            .tr: "Geçmişi Sil",
            .es: "Eliminar historial",
            .fr: "Supprimer l'historique",
            .de: "Verlauf löschen",
            .it: "Elimina cronologia",
            .pt: "Excluir histórico",
            .ja: "履歴を削除",
            .zh: "删除历史记录",
            .ko: "기록 삭제",
            .ru: "Удалить историю",
            .ar: "حذف السجل",
        ],
        .deleteConfirmTitle: [
            .en: "Delete selected clipboard history?",
            .tr: "Seçili pano geçmişi silinsin mi?",
            .es: "¿Eliminar el historial seleccionado?",
            .fr: "Supprimer l'historique sélectionné ?",
            .de: "Ausgewählten Verlauf löschen?",
            .it: "Eliminare la cronologia selezionata?",
            .pt: "Excluir o histórico selecionado?",
            .ja: "選択したクリップボード履歴を削除しますか？",
            .zh: "删除所选剪贴板历史？",
            .ko: "선택한 클립보드 기록을 삭제하시겠습니까?",
            .ru: "Удалить выбранную историю?",
            .ar: "هل تريد حذف سجل الحافظة المحدد؟",
        ],
        .deleteEmptyHint: [
            .en: "No matching unpinned items to delete.",
            .tr: "Silinecek eşleşen öğe yok.",
            .es: "No hay elementos coincidentes para eliminar.",
            .fr: "Aucun élément correspondant à supprimer.",
            .de: "Keine passenden Elemente zum Löschen.",
            .it: "Nessun elemento corrispondente da eliminare.",
            .pt: "Nenhum item correspondente para excluir.",
            .ja: "削除対象の一致する項目がありません。",
            .zh: "没有匹配的未固定项目可删除。",
            .ko: "삭제할 일치 항목이 없습니다.",
            .ru: "Нет подходящих элементов для удаления.",
            .ar: "لا توجد عناصر مطابقة للحذف.",
        ],
        .searchPlaceholder: [
            .en: "Search",
            .tr: "Ara",
            .es: "Buscar",
            .fr: "Rechercher",
            .de: "Suchen",
            .it: "Cerca",
            .pt: "Buscar",
            .ja: "検索",
            .zh: "搜索",
            .ko: "검색",
            .ru: "Поиск",
            .ar: "بحث",
        ],
        .searchButton: [
            .en: "Search",
            .tr: "Ara",
            .es: "Buscar",
            .fr: "Rechercher",
            .de: "Suchen",
            .it: "Cerca",
            .pt: "Buscar",
            .ja: "検索",
            .zh: "搜索",
            .ko: "검색",
            .ru: "Поиск",
            .ar: "بحث",
        ],
        .historyEmpty: [
            .en: "Nothing copied yet.",
            .tr: "Henüz bir şey kopyalanmadı.",
            .es: "Nada copiado aún.",
            .fr: "Rien de copié pour le moment.",
            .de: "Noch nichts kopiert.",
            .it: "Nulla ancora copiato.",
            .pt: "Nada copiado ainda.",
            .ja: "まだコピーされた項目がありません。",
            .zh: "尚未复制任何内容。",
            .ko: "아직 복사된 항목이 없습니다.",
            .ru: "Пока ничего не скопировано.",
            .ar: "لم يتم نسخ شيء بعد.",
        ],
        .searchEmpty: [
            .en: "No results.",
            .tr: "Sonuç yok.",
            .es: "Sin resultados.",
            .fr: "Aucun résultat.",
            .de: "Keine Ergebnisse.",
            .it: "Nessun risultato.",
            .pt: "Sem resultados.",
            .ja: "結果がありません。",
            .zh: "无结果。",
            .ko: "결과가 없습니다.",
            .ru: "Нет результатов.",
            .ar: "لا توجد نتائج.",
        ],
        .historyImage: [
            .en: "Image",
            .tr: "Görsel",
            .es: "Imagen",
            .fr: "Image",
            .de: "Bild",
            .it: "Immagine",
            .pt: "Imagem",
            .ja: "画像",
            .zh: "图片",
            .ko: "이미지",
            .ru: "Изображение",
            .ar: "صورة",
        ],
        .historyOptions: [
            .en: "Options",
            .tr: "Seçenekler",
            .es: "Opciones",
            .fr: "Options",
            .de: "Optionen",
            .it: "Opzioni",
            .pt: "Opções",
            .ja: "オプション",
            .zh: "选项",
            .ko: "옵션",
            .ru: "Параметры",
            .ar: "خيارات",
        ],
        .settingsOpen: [
            .en: "Settings…",
            .tr: "Ayarlar…",
            .es: "Ajustes…",
            .fr: "Réglages…",
            .de: "Einstellungen…",
            .it: "Impostazioni…",
            .pt: "Ajustes…",
            .ja: "設定…",
            .zh: "设置…",
            .ko: "설정…",
            .ru: "Настройки…",
            .ar: "الإعدادات…",
        ],
        .deleteHistoryMenu: [
            .en: "Delete History…",
            .tr: "Geçmişi Sil…",
            .es: "Eliminar historial…",
            .fr: "Supprimer l'historique…",
            .de: "Verlauf löschen…",
            .it: "Elimina cronologia…",
            .pt: "Excluir histórico…",
            .ja: "履歴を削除…",
            .zh: "删除历史…",
            .ko: "기록 삭제…",
            .ru: "Удалить историю…",
            .ar: "حذف السجل…",
        ],
        .appQuit: [
            .en: "Quit Kastor",
            .tr: "Kastor’dan Çık",
            .es: "Salir de Kastor",
            .fr: "Quitter Kastor",
            .de: "Kastor beenden",
            .it: "Esci da Kastor",
            .pt: "Sair do Kastor",
            .ja: "Kastor を終了",
            .zh: "退出 Kastor",
            .ko: "Kastor 종료",
            .ru: "Выйти из Kastor",
            .ar: "إنهاء Kastor",
        ],
        .pinItem: [
            .en: "Pin",
            .tr: "Sabitle",
            .es: "Fijar",
            .fr: "Épingler",
            .de: "Anheften",
            .it: "Fissa",
            .pt: "Fixar",
            .ja: "ピン留め",
            .zh: "固定",
            .ko: "고정",
            .ru: "Закрепить",
            .ar: "تثبيت",
        ],
        .unpinItem: [
            .en: "Unpin",
            .tr: "Sabitlemeyi Kaldır",
            .es: "Desfijar",
            .fr: "Désépingler",
            .de: "Lösen",
            .it: "Rimuovi fissaggio",
            .pt: "Desafixar",
            .ja: "ピン留め解除",
            .zh: "取消固定",
            .ko: "고정 해제",
            .ru: "Открепить",
            .ar: "إلغاء التثبيت",
        ],
        .removeItem: [
            .en: "Remove Item",
            .tr: "Öğeyi Sil",
            .es: "Eliminar elemento",
            .fr: "Supprimer l'élément",
            .de: "Element entfernen",
            .it: "Rimuovi elemento",
            .pt: "Remover item",
            .ja: "項目を削除",
            .zh: "移除项目",
            .ko: "항목 제거",
            .ru: "Удалить элемент",
            .ar: "إزالة العنصر",
        ],
        .cancel: [
            .en: "Cancel",
            .tr: "Vazgeç",
            .es: "Cancelar",
            .fr: "Annuler",
            .de: "Abbrechen",
            .it: "Annulla",
            .pt: "Cancelar",
            .ja: "キャンセル",
            .zh: "取消",
            .ko: "취소",
            .ru: "Отмена",
            .ar: "إلغاء",
        ],
        .deleteAction: [
            .en: "Delete",
            .tr: "Sil",
            .es: "Eliminar",
            .fr: "Supprimer",
            .de: "Löschen",
            .it: "Elimina",
            .pt: "Excluir",
            .ja: "削除",
            .zh: "删除",
            .ko: "삭제",
            .ru: "Удалить",
            .ar: "حذف",
        ],
        .pinnedLabel: [
            .en: "Pinned",
            .tr: "Sabitli",
            .es: "Fijado",
            .fr: "Épinglé",
            .de: "Angeheftet",
            .it: "Fissato",
            .pt: "Fixado",
            .ja: "ピン留め",
            .zh: "已固定",
            .ko: "고정됨",
            .ru: "Закреплено",
            .ar: "مثبت",
        ],
    ]
}
