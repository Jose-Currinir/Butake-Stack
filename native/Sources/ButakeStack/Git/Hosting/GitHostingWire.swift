import Foundation

// The JSON of each provider's API as the tool reads it (only the fields it uses). Field names
// follow the providers.

struct GHUser: Decodable { var login: String; var name: String? }
struct GHRef: Decodable { var ref: String; var sha: String? }
struct GHPull: Decodable {
    var number: Int; var title: String; var body: String?; var state: String; var user: GHUser; var head: GHRef; var base: GHRef
    var html_url: String?; var merged_at: String?; var updated_at: String?; var draft: Bool?
}
struct GHComment: Decodable { var id: Int; var user: GHUser?; var body: String?; var created_at: String?; var path: String?; var line: Int?; var original_line: Int? }
struct GHReview: Decodable { var user: GHUser?; var state: String }
struct GHCheckRuns: Decodable {
    var check_runs: [Run]
    struct Run: Decodable { var id: Int; var name: String; var status: String; var conclusion: String?; var html_url: String? }
}
struct GHRepo: Decodable { var full_name: String; var ssh_url: String; var clone_url: String; var updated_at: String?; var `private`: Bool; var description: String? }
struct GHOrg: Decodable { var login: String }
struct GHBranch: Decodable { var protected: Bool }
struct GHRule: Decodable { var type: String }

struct BBPage<T: Decodable>: Decodable { var values: [T]; var next: String? }
struct BBUser: Decodable { var display_name: String?; var username: String?; var nickname: String? }
struct BBLinks: Decodable { var html: Href?; var clone: [Clone]?; struct Href: Decodable { var href: String }; struct Clone: Decodable { var name: String; var href: String } }
struct BBRevision: Decodable { var branch: Name; var commit: Hash?; struct Name: Decodable { var name: String }; struct Hash: Decodable { var hash: String } }
struct BBPull: Decodable {
    var id: Int; var title: String; var description: String?; var state: String; var author: BBUser; var source: BBRevision; var destination: BBRevision
    var links: BBLinks; var updated_on: String?; var draft: Bool?
}
struct BBComment: Decodable {
    var id: Int; var user: BBUser?; var content: Content; var created_on: String?; var inline: Inline?; var deleted: Bool?
    struct Content: Decodable { var raw: String? }
    struct Inline: Decodable { var path: String?; var to: Int?; var from: Int? }
}
struct BBPullDetail: Decodable {
    var participants: [Participant]
    struct Participant: Decodable { var user: BBUser?; var approved: Bool?; var state: String? }
}
struct BBStatus: Decodable { var key: String; var name: String?; var state: String; var url: String? }
struct BBRepo: Decodable { var full_name: String; var updated_on: String?; var is_private: Bool?; var description: String?; var links: BBLinks }
struct BBWorkspace: Decodable { var slug: String? }
struct BBWorkspaceAccess: Decodable { var workspace: BBWorkspace? }
/// Bitbucket's branching model: the branches it names and the prefixes of the other types.
struct BBBranchingModel: Decodable {
    var development: Named?
    var production: Named?
    var branch_types: [Kind]?
    struct Named: Decodable { var branch: BBRevision.Name?; var use_mainbranch: Bool? }
    struct Kind: Decodable { var kind: String; var prefix: String }

    /// The model names a branch it cannot resolve (the repository's main branch, not given here).
    var unresolved: Bool { [development, production].contains { $0 != nil && $0?.branch == nil } }

    /// The type of `branch` in the model («production», «development», «feature»…), nil when it has none.
    func type(of branch: String) -> String? {
        if production?.branch?.name == branch { return "production" }
        if development?.branch?.name == branch { return "development" }
        return branch_types?.first { !$0.prefix.isEmpty && branch.hasPrefix($0.prefix) }?.kind
    }
}
struct BBRestriction: Decodable { var kind: String; var pattern: String?; var branch_match_kind: String?; var branch_type: String? }
/// An answer whose content does not matter (a POST that only has to succeed).
struct GitHostingIgnored: Decodable {}

extension GHPull {
    var pullRequest: GitPullRequest {
        let mapped: GitPullRequestState = state == "open" ? .open : merged_at != nil ? .merged : .closed
        return GitPullRequest(id: number, title: title, body: body ?? "", state: mapped, draft: draft ?? false, author: user.login,
                              source: head.ref, target: base.ref, head: head.sha, page: html_url.flatMap(URL.init(string:)), updated: gitHostingDate(updated_at))
    }
}

extension BBPull {
    var pullRequest: GitPullRequest {
        let mapped: GitPullRequestState = switch state { case "OPEN": .open; case "MERGED": .merged; default: .closed }
        return GitPullRequest(id: id, title: title, body: description ?? "", state: mapped, draft: draft ?? false, author: author.display_name ?? "—",
                              source: source.branch.name, target: destination.branch.name, head: source.commit?.hash,
                              page: links.html.flatMap { URL(string: $0.href) }, updated: gitHostingDate(updated_on))
    }
}

extension GHRepo {
    var remote: GitHostingRemoteRepository {
        GitHostingRemoteRepository(provider: .github, fullName: full_name, ssh: ssh_url, https: clone_url, isPrivate: `private`,
                                   summary: description ?? "", updated: gitHostingDate(updated_at))
    }
}

extension BBRepo {
    func remote(_ endpoints: GitHostingEndpoints) -> GitHostingRemoteRepository {
        let links = links.clone ?? []
        let fallback = GitHostedRepository.cloneAddresses(provider: .bitbucket, path: full_name, endpoints: endpoints)
        // Bitbucket's HTTPS address carries the user name («https://usuario@…»): left out.
        let https = links.first { $0.name == "https" }?.href.replacingOccurrences(of: #"https://[^@/]+@"#, with: "https://", options: .regularExpression)
        return GitHostingRemoteRepository(provider: .bitbucket, fullName: full_name, ssh: links.first { $0.name == "ssh" }?.href ?? fallback.ssh,
                                          https: https ?? fallback.https, isPrivate: is_private ?? true, summary: description ?? "", updated: gitHostingDate(updated_on))
    }
}
