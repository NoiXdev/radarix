import Foundation
import RadarixKit

extension RepoRef {
    /// The repository's page on github.com.
    var githubURL: URL? { URL(string: "https://github.com/\(owner)/\(name)") }
}
