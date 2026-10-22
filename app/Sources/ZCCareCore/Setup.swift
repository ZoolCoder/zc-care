import Foundation

/// Who a Mac can be for, from `init -list -json`.
public struct StarterCatalog: Decodable, Sendable, Equatable {
    public struct Profile: Decodable, Sendable, Equatable, Identifiable {
        public var name: String
        public var title: String
        public var about: String
        public var id: String { name }

        public init(name: String, title: String, about: String) {
            self.name = name
            self.title = title
            self.about = about
        }
    }

    public var profiles: [Profile]
    public var roles: [String]

    public init(profiles: [Profile], roles: [String]) {
        self.profiles = profiles
        self.roles = roles
    }
}

/// What `init -json` wrote.
public struct InitResult: Decodable, Sendable, Equatable {
    public var config: String
    public var files: [String]
    /// The other profiles' packages, now on the skip list.
    public var skip: [String]?
    /// The packages this Mac had that the starter lacked.
    public var kept: Int
    public var profiles: [String]?
}

extension CareCLI {
    public func starter() async throws -> StarterCatalog { try await json(["init", "-list", "-json"]) }

    /// Writes the starter config for these profiles, puts the other
    /// profiles' packages on the skip list and saves who the Mac is for.
    /// It installs nothing.
    public func initConfig(profiles: [String], role: String?, fromMac: Bool) async throws -> InitResult {
        var args = ["init", "-json", "-profile", profiles.joined(separator: ",")]
        if let role { args += ["-role", role] }
        if fromMac { args.append("-from-mac") }
        return try await json(args)
    }

    /// Who this Mac is for; empty is everyone, so every target applies.
    public func machineProfiles() async throws -> [String] { try await json(["profile", "-json"]) }

    public func setMachineProfiles(_ profiles: [String]) async throws -> [String] {
        try await json(["profile", "-json"] + (profiles.isEmpty ? ["-clear"] : profiles))
    }
}

extension Fix {
    /// A failed check and the command that fixes it as root.
    public struct RootStep: Sendable, Equatable, Identifiable {
        public var title: String
        public var command: String

        public var id: String { title }
    }

    /// The root fix of each failed check, in order.
    public static func rootSteps(for checks: [Check]) -> [RootStep] {
        checks.filter { !$0.isOK }.compactMap { check in
            if case .command(let c) = Fix(for: check) { return RootStep(title: check.title, command: c) }
            return nil
        }
    }

    /// The root fixes of every failed check, run as one command, so one
    /// password dialog secures the Mac. Nil when none can run as root.
    public static func rootCommands(for checks: [Check]) -> String? {
        joined(rootSteps(for: checks))
    }
}

/// How far this Mac is set up for a developer: Apple's command line tools,
/// git's name and email, an SSH key that signs commits, and GitHub.
public struct DevIdentity: Sendable, Equatable {
    public var tools = false
    public var name = ""
    public var email = ""
    /// The public key's path, when there is one.
    public var key: String?
    /// Commits are signed with an SSH key.
    public var signing = false
    public var github = false

    public init() {}

    public var complete: Bool { tools && !name.isEmpty && !email.isEmpty && key != nil && signing && github }

    static let keyName = "id_ed25519"

    /// Reads what is set up. git is read only once the command line tools
    /// are in: without them /usr/bin/git asks to install them.
    public static func read(runner: any Runner = ProcessRunner(timeout: 20), env: [String: String], home: String,
                            exists: (String) -> Bool = FileManager.default.fileExists) async -> DevIdentity {
        var id = DevIdentity()
        id.tools = (try? await runner.run("/usr/bin/xcode-select", ["-p"], env: env))?.status == 0
        let pub = home + "/.ssh/" + keyName + ".pub"
        if exists(pub) { id.key = pub }
        guard id.tools else { return id }
        func git(_ key: String) async -> String {
            let r = try? await runner.run("/usr/bin/git", ["config", "--global", key], env: env)
            return r?.status == 0 ? r!.output.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        }
        id.name = await git("user.name")
        id.email = await git("user.email")
        let format = await git("gpg.format"), signingKey = await git("user.signingkey")
        id.signing = format == "ssh" && !signingKey.isEmpty
        id.github = (try? await runner.run("/usr/bin/env", ["gh", "auth", "status"], env: env))?.status == 0
        return id
    }

    /// Sets git's name and email for every repository.
    public static func setGit(name: String, email: String, runner: any Runner = ProcessRunner(timeout: 20),
                              env: [String: String]) async throws {
        for (key, value) in [("user.name", name), ("user.email", email)] {
            let r = try await runner.run("/usr/bin/git", ["config", "--global", key, value], env: env)
            if r.status != 0 { throw CLIError(message: lastLine(r.stderr) ?? "git config exited \(r.status)") }
        }
    }

    /// A Terminal script that makes an SSH key behind a passphrase the
    /// keychain keeps, signs commits with it, signs in to GitHub and
    /// uploads the key for both. Each step is skipped once done.
    public static func script(email: String) -> String {
        """
        #!/bin/zsh
        # ZC Care: set up this Mac's SSH key, commit signing and GitHub.
        set -e
        export PATH="/opt/homebrew/bin:$PATH"
        key="$HOME/.ssh/\(keyName)"
        if [ ! -f "$key" ]; then
          mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
          echo "Choose a passphrase for your new SSH key. The keychain remembers it."
          ssh-keygen -t ed25519 -C \(shellQuoted(email)) -f "$key"
        fi
        ssh-add --apple-use-keychain "$key"
        if ! grep -q UseKeychain "$HOME/.ssh/config" 2>/dev/null; then
          printf 'Host *\\n  AddKeysToAgent yes\\n  UseKeychain yes\\n  IdentityFile ~/.ssh/\(keyName)\\n' >> "$HOME/.ssh/config"
        fi
        git config --global gpg.format ssh
        git config --global user.signingkey "$key.pub"
        git config --global commit.gpgsign true
        if command -v gh >/dev/null; then
          scopes=admin:public_key,admin:ssh_signing_key
          if gh auth status >/dev/null 2>&1; then
            gh auth refresh -h github.com -s "$scopes"
          else
            gh auth login -h github.com -p ssh -s "$scopes" --web
          fi
          mac="$(scutil --get ComputerName)"
          gh ssh-key add "$key.pub" --type authentication --title "$mac" || true
          gh ssh-key add "$key.pub" --type signing --title "$mac signing" || true
        else
          echo "Install gh with Choose Apps, then run this again to add the key to GitHub."
        fi
        echo "Done. You can close this window."
        """
    }

    /// Writes the script where Terminal can open it.
    public static func writeScript(email: String, to dir: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let file = dir.appendingPathComponent("zccare-developer-identity.command")
        try script(email: email).write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return file
    }
}

/// s in single quotes, for a shell.
func shellQuoted(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
