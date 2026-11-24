import RadarixKit

/// A row a layout should scroll into view.
enum ScrollTarget: Hashable {
    /// The repository's section in the single list.
    case repo(RepoID)
    case item(ItemKey)
}

/// What a deep link changes in the main window.
struct MainNavigation: Equatable {
    /// Nil leaves the sidebar's choice as it is.
    var sidebar: SidebarItem?
    /// The item to select, nil for none. Ignored when `keepsSelection` is set.
    var selection: ItemKey?
    var keepsSelection = false
    var scroll: ScrollTarget?

    /// Nil when the link only brings the window to the front.
    ///
    /// A repo that is not watched leads to "All"; an item that is not listed selects nothing.
    /// In the single list a repo link only scrolls to that repo's section.
    init?(_ link: DeepLink, in account: AccountData, layout: MainLayout) {
        switch link {
        case .main:
            return nil
        case .repo(let id):
            let watched = account.repos[id] != nil
            switch layout {
            case .sidebar:
                sidebar = watched ? .repo(id) : .all
            case .grouped:
                keepsSelection = true
                scroll = watched ? .repo(id) : nil
            }
        case .item(let key):
            let watched = account.repos[key.repo] != nil
            let listed = account.repos[key.repo]?.records[key.number] != nil
            if layout == .sidebar { sidebar = watched ? .repo(key.repo) : .all }
            selection = listed ? key : nil
            scroll = if listed { .item(key) } else if watched, layout == .grouped { .repo(key.repo) } else { nil }
        }
    }
}
