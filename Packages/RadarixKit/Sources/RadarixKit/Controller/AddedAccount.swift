/// The account a sign-in ended up as. `isNew` is false when that account was already in the
/// list, so the sign-in only renewed its credential.
public struct AddedAccount: Sendable, Equatable {
    public let accountID: AccountID
    public let login: String
    public let isNew: Bool

    public init(accountID: AccountID, login: String, isNew: Bool) {
        self.accountID = accountID
        self.login = login
        self.isNew = isNew
    }
}
