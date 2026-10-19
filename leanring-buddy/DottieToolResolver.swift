//
//  DottieToolResolver.swift
//  leanring-buddy
//
//  Turns "install ffmpeg", "the Vercel CLI" or "yt-dlp" into a real package
//  Dottie can install, checked against the real package lists:
//
//    1. A short list of well-known tools whose names people say loosely
//       ("the AWS CLI", "Docker", "something to download YouTube videos").
//    2. The Tools tab's catalog.
//    3. Homebrew formulae and casks (`brew info --json=v2`, or the
//       formulae.brew.sh API when Homebrew isn't installed yet), then npm,
//       PyPI and crates.io, all asked at once. Homebrew wins when it has it.
//
//  Nothing here installs anything; DottieToolInstaller does that after the
//  user says yes.
//

import Foundation

/// Where a tool comes from.
enum DottieToolSource: String, Codable, CaseIterable {
    case homebrew
    case homebrewCask
    case npm
    case pypi
    case cargo
    /// The tool's own official install command (rustup, uv, bun…).
    case script

    /// What the user hears: "from Homebrew".
    var displayName: String {
        switch self {
        case .homebrew, .homebrewCask: return "Homebrew"
        case .npm: return "npm"
        case .pypi: return "PyPI"
        case .cargo: return "crates.io"
        case .script: return "its official installer"
        }
    }

    /// The word the voice tool's `source` argument uses.
    var argumentName: String {
        switch self {
        case .homebrew, .homebrewCask: return "homebrew"
        case .npm: return "npm"
        case .pypi: return "pypi"
        case .cargo: return "cargo"
        case .script: return "official"
        }
    }

    static func fromArgument(_ text: String?) -> DottieToolSource? {
        guard let text = text?.lowercased() else { return nil }
        if text.contains("brew") { return .homebrew }
        if text.contains("npm") || text.contains("node") { return .npm }
        if text.contains("pypi") || text.contains("pip") || text.contains("python") || text == "uv" { return .pypi }
        if text.contains("cargo") || text.contains("crate") || text.contains("rust") { return .cargo }
        return nil
    }
}

/// A package Dottie can install.
struct DottieToolPackage: Codable, Equatable, Identifiable {
    let source: DottieToolSource
    /// The formula, cask, npm package, PyPI project or crate.
    let packageName: String
    /// What the user sees, like "yt-dlp" or "Vercel CLI".
    let title: String
    let summary: String
    var homepage: String?
    /// Programs it adds, when known before installing.
    var commands: [String]
    /// For `.script`: the official install command and how to undo it.
    var scriptInstallCommand: String?
    var scriptUninstallCommand: String?

    var id: String { source.rawValue + ":" + packageName }

    /// The command it runs, shown in the Tools tab.
    var installCommandText: String {
        switch source {
        case .homebrew: return "brew install \(packageName)"
        case .homebrewCask: return "brew install --cask \(packageName)"
        case .npm: return "npm install -g \(packageName)"
        case .pypi: return "uv tool install \(packageName)"
        case .cargo: return "cargo install \(packageName)"
        case .script: return scriptInstallCommand ?? packageName
        }
    }
}

/// Something that has to be installed first.
enum DottieToolPrerequisite: Equatable {
    case homebrew
    /// Dottie's own copy of Node.js (DotsRuntimeInstaller).
    case node
    case uv
    case rust

    var spokenDescription: String {
        switch self {
        case .homebrew: return "Homebrew first, which asks for your Mac password in Terminal"
        case .node: return "Node.js first (Dottie's own copy, about 70 MB)"
        case .uv: return "uv first, a small free Python tool installer"
        case .rust: return "Rust first, with its official installer (a few minutes)"
        }
    }
}

/// What Dottie found for a request.
struct DottieToolPlan: Equatable {
    var package: DottieToolPackage
    /// Other places that have a package by that name, so Dottie can offer
    /// them if she picked the wrong one.
    var alsoFoundOn: [DottieToolSource] = []
    /// Where it already is, when it's on this Mac.
    var existingPath: String?
    var prerequisite: DottieToolPrerequisite?

    var isAlreadyInstalled: Bool { existingPath != nil }

    /// "yt-dlp from Homebrew: Downloads videos…"
    var oneLine: String {
        var line = "\(package.title) from \(package.source.displayName)"
        if !package.summary.isEmpty { line += ": \(package.summary)" }
        if let prerequisite { line += " (needs \(prerequisite.spokenDescription))" }
        return line
    }
}

enum DottieToolResolution: Equatable {
    case found(DottieToolPlan)
    case notFound(request: String, suggestions: [String])
}

enum DottieToolResolver {
    // MARK: - Well-known tools

    /// Tools people ask for by a loose name or by what they do. Every
    /// package name here was checked against Homebrew, npm or PyPI.
    private struct KnownTool {
        /// Names that must be the whole request ("aws", "aws cli").
        let phrases: [String]
        /// Words that can appear anywhere in a longer ask ("something to
        /// download youtube videos").
        var descriptions: [String] = []
        let package: DottieToolPackage
    }

    private static func brew(_ name: String, _ title: String, _ summary: String, commands: [String], cask: Bool = false) -> DottieToolPackage {
        DottieToolPackage(source: cask ? .homebrewCask : .homebrew, packageName: name, title: title, summary: summary, commands: commands)
    }

    private static let knownTools: [KnownTool] = [
        KnownTool(phrases: ["youtube-dl", "yt-dlp", "ytdlp", "youtube downloader"], descriptions: ["youtube", "download video", "download videos", "video downloader"],
                  package: brew("yt-dlp", "yt-dlp", "Downloads videos and audio from YouTube and many other sites.", commands: ["yt-dlp"])),
        KnownTool(phrases: ["ffmpeg"], descriptions: ["convert video", "convert videos", "video converter"],
                  package: brew("ffmpeg", "FFmpeg", "Converts, trims and joins video and audio.", commands: ["ffmpeg", "ffprobe"])),
        KnownTool(phrases: ["vercel", "vercel cli"],
                  package: DottieToolPackage(source: .npm, packageName: "vercel", title: "Vercel CLI", summary: "Deploys websites to Vercel from Terminal.", homepage: "https://vercel.com/docs/cli", commands: ["vercel", "vc"])),
        KnownTool(phrases: ["netlify", "netlify cli"],
                  package: brew("netlify-cli", "Netlify CLI", "Deploys websites to Netlify from Terminal.", commands: ["netlify"])),
        KnownTool(phrases: ["firebase", "firebase cli", "firebase tools"],
                  package: brew("firebase-cli", "Firebase CLI", "Works with Google Firebase projects from Terminal.", commands: ["firebase"])),
        KnownTool(phrases: ["wrangler", "cloudflare", "cloudflare cli", "cloudflare workers"],
                  package: brew("cloudflare-wrangler", "Wrangler", "Cloudflare's tool for Workers and Pages.", commands: ["wrangler"])),
        KnownTool(phrases: ["aws", "aws cli", "amazon web services"],
                  package: brew("awscli", "AWS CLI", "Works with Amazon Web Services from Terminal.", commands: ["aws"])),
        KnownTool(phrases: ["gcloud", "google cloud", "google cloud cli", "google cloud sdk"],
                  package: brew("gcloud-cli", "Google Cloud CLI", "Works with Google Cloud from Terminal.", commands: ["gcloud"], cask: true)),
        KnownTool(phrases: ["heroku", "heroku cli"],
                  package: brew("heroku", "Heroku CLI", "Works with Heroku apps from Terminal.", commands: ["heroku"])),
        KnownTool(phrases: ["supabase", "supabase cli"],
                  package: brew("supabase", "Supabase CLI", "Works with Supabase projects from Terminal.", commands: ["supabase"])),
        KnownTool(phrases: ["flyctl", "fly io", "fly.io"],
                  package: brew("flyctl", "flyctl", "Deploys apps to Fly.io.", commands: ["flyctl", "fly"])),
        KnownTool(phrases: ["railway", "railway cli"],
                  package: brew("railway", "Railway CLI", "Deploys apps to Railway.", commands: ["railway"])),
        KnownTool(phrases: ["kubectl", "kubernetes"],
                  package: brew("kubernetes-cli", "kubectl", "Controls Kubernetes clusters.", commands: ["kubectl"])),
        KnownTool(phrases: ["docker", "docker desktop"],
                  package: brew("docker-desktop", "Docker Desktop", "Runs containers on this Mac (the docker command).", commands: ["docker"], cask: true)),
        KnownTool(phrases: ["ngrok"],
                  package: brew("ngrok", "ngrok", "Shares a website running on this Mac with a public link.", commands: ["ngrok"], cask: true)),
        KnownTool(phrases: ["stripe", "stripe cli"],
                  package: brew("stripe/stripe-cli/stripe", "Stripe CLI", "Works with Stripe payments from Terminal (Stripe's own Homebrew tap).", commands: ["stripe"])),
        KnownTool(phrases: ["terraform"],
                  package: brew("hashicorp/tap/terraform", "Terraform", "Sets up cloud servers from config files (HashiCorp's own Homebrew tap).", commands: ["terraform"])),
        KnownTool(phrases: ["whisper", "openai whisper"], descriptions: ["transcribe audio", "speech to text"],
                  package: DottieToolPackage(source: .pypi, packageName: "openai-whisper", title: "Whisper", summary: "Turns speech in audio and video files into text, offline.", homepage: "https://github.com/openai/whisper", commands: ["whisper"])),
        KnownTool(phrases: ["rust", "rustup", "cargo"],
                  package: rustupPackage)
    ]

    /// Rust's official installer. No password; lives in ~/.cargo.
    static let rustupPackage = DottieToolPackage(
        source: .script,
        packageName: "rustup",
        title: "Rust",
        summary: "The Rust language and cargo, which installs Rust tools.",
        homepage: "https://rustup.rs",
        commands: ["cargo", "rustc", "rustup"],
        scriptInstallCommand: "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path",
        scriptUninstallCommand: "\"$HOME/.cargo/bin/rustup\" self uninstall -y"
    )

    /// Tools whose own installer needs no password, used instead of
    /// Homebrew when Homebrew isn't on the Mac. Keyed by Homebrew name.
    private static let officialInstallersByBrewName: [String: DottieToolPackage] = [
        "uv": DottieToolPackage(
            source: .script, packageName: "uv", title: "uv", summary: "Installs and runs Python tools fast (uvx).",
            homepage: "https://docs.astral.sh/uv/", commands: ["uv", "uvx"],
            scriptInstallCommand: "curl -LsSf https://astral.sh/uv/install.sh | env UV_NO_MODIFY_PATH=1 sh",
            scriptUninstallCommand: "rm -f \"$HOME/.local/bin/uv\" \"$HOME/.local/bin/uvx\""
        ),
        "bun": DottieToolPackage(
            source: .script, packageName: "bun", title: "Bun", summary: "Fast JavaScript runtime and package manager.",
            homepage: "https://bun.sh", commands: ["bun", "bunx"],
            scriptInstallCommand: "curl -fsSL https://bun.sh/install | bash",
            scriptUninstallCommand: "rm -rf \"$HOME/.bun\""
        ),
        "claude-code": DottieToolPackage(
            source: .script, packageName: "claude-code", title: "Claude Code", summary: "Anthropic's AI coding helper for Terminal.",
            homepage: "https://docs.anthropic.com/en/docs/claude-code", commands: ["claude"],
            scriptInstallCommand: "curl -fsSL https://claude.ai/install.sh | bash",
            scriptUninstallCommand: "rm -f \"$HOME/.local/bin/claude\"; rm -rf \"$HOME/.local/share/claude\""
        ),
        "rustup": rustupPackage
    ]

    // MARK: - Resolving

    /// Finds the package for a request like "ffmpeg" or "the vercel cli".
    /// `preferredSource` limits the search to one place.
    static func resolve(_ request: String, preferredSource: DottieToolSource? = nil) async -> DottieToolResolution {
        await DottieCommandLocator.warmUp()
        let cleanedRequest = cleaned(request)
        guard !cleanedRequest.isEmpty else { return .notFound(request: request, suggestions: []) }

        if preferredSource == nil, let knownPackage = knownPackage(for: cleanedRequest) {
            let knownPlan = await plan(for: knownPackage)
            return .found(knownPlan)
        }
        if preferredSource == nil || preferredSource == .homebrew,
           let catalogTool = DottieCLICatalog.all.first(where: { matches(cleanedRequest, catalogTool: $0) }) {
            let package = DottieToolPackage(
                source: catalogTool.isCask ? .homebrewCask : .homebrew,
                packageName: catalogTool.brewName,
                title: catalogTool.title,
                summary: catalogTool.summary,
                commands: [catalogTool.command]
            )
            let catalogPlan = await plan(for: package)
            return .found(catalogPlan)
        }

        // A long description ("something that edits photos") isn't a name.
        let wordCount = cleanedRequest.split(separator: " ").count
        guard wordCount <= 3 else { return .notFound(request: request, suggestions: []) }

        let names = candidateNames(for: cleanedRequest)
        // Every place is asked at once; an empty list skips one.
        let homebrewNames = preferredSource == nil || preferredSource == .homebrew ? names : []
        let npmNames = preferredSource == nil || preferredSource == .npm ? names : []
        let pypiNames = preferredSource == nil || preferredSource == .pypi ? names : []
        let cargoNames = preferredSource == nil || preferredSource == .cargo ? names : []
        async let homebrewMatch = lookUpHomebrew(homebrewNames)
        async let npmMatch = lookUpNPM(npmNames)
        async let pypiMatch = lookUpPyPI(pypiNames)
        async let cargoMatch = lookUpCrate(cargoNames)
        let homebrewResult = await homebrewMatch
        let npmResult = await npmMatch
        let pypiResult = await pypiMatch
        let cargoResult = await cargoMatch
        let matchesInOrder = [homebrewResult, npmResult, pypiResult, cargoResult].compactMap { $0 }

        guard let bestMatch = matchesInOrder.first else {
            let suggestions = await homebrewSuggestions(for: names.first ?? cleanedRequest)
            return .notFound(request: request, suggestions: suggestions)
        }
        var resolvedPlan = await plan(for: bestMatch.package, isAlreadyInstalledByHomebrew: bestMatch.isInstalledByHomebrew)
        resolvedPlan.alsoFoundOn = matchesInOrder.dropFirst().map(\.package.source)
        return .found(resolvedPlan)
    }

    /// Adds what's already on the Mac and what has to be installed first.
    private static func plan(for package: DottieToolPackage, isAlreadyInstalledByHomebrew: Bool = false) async -> DottieToolPlan {
        var resolvedPackage = package
        let hasHomebrew = DottieCommandLocator.isInstalled("brew")
        // Without Homebrew, a tool with its own no-password installer uses it.
        if !hasHomebrew, package.source == .homebrew || package.source == .homebrewCask,
           let officialPackage = officialInstallersByBrewName[package.packageName] {
            resolvedPackage = officialPackage
        }

        var plan = DottieToolPlan(package: resolvedPackage)
        if let existingPath = resolvedPackage.commands.lazy.compactMap({ DottieCommandLocator.locate($0) }).first {
            plan.existingPath = existingPath
        } else if isAlreadyInstalledByHomebrew {
            plan.existingPath = "Homebrew"
        }

        switch resolvedPackage.source {
        case .homebrew, .homebrewCask:
            if !hasHomebrew { plan.prerequisite = .homebrew }
        case .npm:
            if !DottieCommandLocator.isInstalled("npm") && !DotsRuntimeInstaller.isInstalled { plan.prerequisite = .node }
        case .pypi:
            if !DottieCommandLocator.isInstalled("uv") && !DottieCommandLocator.isInstalled("pipx") { plan.prerequisite = .uv }
        case .cargo:
            if !DottieCommandLocator.isInstalled("cargo") { plan.prerequisite = .rust }
        case .script:
            break
        }
        return plan
    }

    // MARK: - Names

    /// Lowercased, without filler like "the" or "command line tool".
    static func cleaned(_ request: String) -> String {
        var text = request.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters.subtracting(CharacterSet(charactersIn: "@/-_."))))
        for prefix in ["install ", "get me ", "get ", "the "] where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
        }
        for suffix in [" command line tool", " command-line tool", " cli tool", " terminal tool", " tool", " app", " program"] where text.hasSuffix(suffix) {
            text = String(text.dropLast(suffix.count))
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// Package names to try: "vercel cli" → vercel-cli, vercel.
    private static func candidateNames(for cleanedRequest: String) -> [String] {
        if cleanedRequest.hasPrefix("@") { return [cleanedRequest] }
        let slug = cleanedRequest.replacingOccurrences(of: " ", with: "-")
        var names = [slug]
        if slug.hasSuffix("-cli") {
            names.append(String(slug.dropLast(4)))
        } else if !slug.contains("/") {
            names.append(slug + "-cli")
        }
        return names
    }

    private static func knownPackage(for cleanedRequest: String) -> DottieToolPackage? {
        let requestWithoutCLI = cleanedRequest.hasSuffix(" cli") ? String(cleanedRequest.dropLast(4)) : cleanedRequest
        if let exactMatch = knownTools.first(where: { $0.phrases.contains(cleanedRequest) || $0.phrases.contains(requestWithoutCLI) }) {
            return exactMatch.package
        }
        let requestWords = words(of: cleanedRequest)
        return knownTools.first { knownTool in
            knownTool.descriptions.contains { containsPhrase(words(of: $0), in: requestWords) }
        }?.package
    }

    private static func matches(_ cleanedRequest: String, catalogTool: DottieCLITool) -> Bool {
        let candidates = [catalogTool.id, catalogTool.title.lowercased(), catalogTool.command.lowercased(), catalogTool.brewName]
        return candidates.contains(cleanedRequest) || candidates.contains(cleanedRequest.replacingOccurrences(of: " ", with: "-"))
    }

    private static func words(of text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "-" && $0 != "." }.map(String.init)
    }

    /// True when `phrase` appears as whole words, in order, in `requestWords`.
    private static func containsPhrase(_ phrase: [String], in requestWords: [String]) -> Bool {
        guard !phrase.isEmpty, phrase.count <= requestWords.count else { return false }
        for startIndex in 0...(requestWords.count - phrase.count)
        where Array(requestWords[startIndex..<(startIndex + phrase.count)]) == phrase {
            return true
        }
        return false
    }

    // MARK: - Homebrew

    private struct Match {
        let package: DottieToolPackage
        var isInstalledByHomebrew = false
    }

    private static func lookUpHomebrew(_ names: [String]) async -> Match? {
        if let brewPath = DottieCommandLocator.locate("brew") {
            for name in names {
                if let match = await brewInfo(name, brewPath: brewPath) { return match }
            }
            return nil
        }
        // Not installed yet: Homebrew's public API knows the same packages.
        for name in names where !name.contains("/") {
            if let formula = await fetchJSON("https://formulae.brew.sh/api/formula/\(name).json"),
               let match = homebrewMatch(formula: formula) { return match }
            if let cask = await fetchJSON("https://formulae.brew.sh/api/cask/\(name).json"),
               let match = homebrewMatch(cask: cask) { return match }
        }
        return nil
    }

    private static func brewInfo(_ name: String, brewPath: String) async -> Match? {
        let result = await DottieProcessRunner.run(
            brewPath,
            arguments: ["info", "--json=v2", name],
            environment: DottieProcessRunner.homebrewEnvironment,
            timeout: 40
        )
        guard result.exitCode == 0,
              let data = result.output.data(using: .utf8),
              let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let formula = (info["formulae"] as? [[String: Any]])?.first, let match = homebrewMatch(formula: formula) {
            return match
        }
        if let cask = (info["casks"] as? [[String: Any]])?.first, let match = homebrewMatch(cask: cask) {
            return match
        }
        return nil
    }

    private static func homebrewMatch(formula: [String: Any]) -> Match? {
        guard let name = (formula["full_name"] as? String) ?? (formula["name"] as? String) else { return nil }
        let shortName = (formula["name"] as? String) ?? name
        let installedVersions = formula["installed"] as? [Any] ?? []
        let package = DottieToolPackage(
            source: .homebrew,
            packageName: name,
            title: shortName,
            summary: sentence(formula["desc"] as? String),
            homepage: formula["homepage"] as? String,
            commands: [shortName]
        )
        return Match(package: package, isInstalledByHomebrew: !installedVersions.isEmpty)
    }

    private static func homebrewMatch(cask: [String: Any]) -> Match? {
        guard let token = (cask["full_token"] as? String) ?? (cask["token"] as? String) else { return nil }
        let displayName = (cask["name"] as? [String])?.first ?? token
        let package = DottieToolPackage(
            source: .homebrewCask,
            packageName: token,
            title: displayName,
            summary: sentence(cask["desc"] as? String),
            homepage: cask["homepage"] as? String,
            commands: caskBinaries(cask)
        )
        let installedVersion = cask["installed"] as? String
        return Match(package: package, isInstalledByHomebrew: installedVersion?.isEmpty == false)
    }

    /// The programs a cask links, from its "binary" artifacts.
    static func caskBinaries(_ cask: [String: Any]) -> [String] {
        var binaries: [String] = []
        for artifact in cask["artifacts"] as? [[String: Any]] ?? [] {
            guard let binaryEntry = artifact["binary"] as? [Any] else { continue }
            if let options = binaryEntry.last as? [String: Any], let target = options["target"] as? String {
                binaries.append((target as NSString).lastPathComponent)
            } else if let sourcePath = binaryEntry.first as? String {
                binaries.append((sourcePath as NSString).lastPathComponent)
            }
        }
        return binaries
    }

    /// Close Homebrew names for a name that matched nothing.
    private static func homebrewSuggestions(for name: String) async -> [String] {
        guard let brewPath = DottieCommandLocator.locate("brew"), !name.contains("/") else { return [] }
        let result = await DottieProcessRunner.run(
            brewPath,
            arguments: ["search", name],
            environment: DottieProcessRunner.homebrewEnvironment,
            timeout: 40
        )
        guard result.exitCode == 0 else { return [] }
        let names = result.output.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("==>") && !$0.contains(" ") }
        return Array(names.prefix(6))
    }

    // MARK: - npm, PyPI, crates.io

    private static func lookUpNPM(_ names: [String]) async -> Match? {
        for name in names {
            guard let latest = await fetchJSON("https://registry.npmjs.org/\(name)/latest"),
                  let packageName = latest["name"] as? String else { continue }
            var commands: [String] = []
            if let binMap = latest["bin"] as? [String: Any] {
                commands = binMap.keys.sorted()
            } else if latest["bin"] is String {
                commands = [packageName.components(separatedBy: "/").last ?? packageName]
            }
            // Without a program it's a code library, not a tool.
            guard !commands.isEmpty else { continue }
            // The program named like the package goes first.
            let shortName = packageName.components(separatedBy: "/").last ?? packageName
            commands = commands.filter { $0 == shortName } + commands.filter { $0 != shortName }
            let package = DottieToolPackage(
                source: .npm,
                packageName: packageName,
                title: packageName,
                summary: sentence(latest["description"] as? String),
                homepage: latest["homepage"] as? String,
                commands: commands
            )
            return Match(package: package)
        }
        return nil
    }

    private static func lookUpPyPI(_ names: [String]) async -> Match? {
        for name in names where !name.hasPrefix("@") && !name.contains("/") {
            guard let project = await fetchJSON("https://pypi.org/pypi/\(name)/json"),
                  let info = project["info"] as? [String: Any],
                  let projectName = info["name"] as? String else { continue }
            let projectURLs = info["project_urls"] as? [String: Any]
            let homepage = (info["home_page"] as? String) ?? (projectURLs?["Homepage"] as? String) ?? (projectURLs?["Repository"] as? String)
            let package = DottieToolPackage(
                source: .pypi,
                packageName: projectName,
                title: projectName,
                summary: sentence(info["summary"] as? String),
                homepage: homepage,
                commands: [projectName.lowercased()]
            )
            return Match(package: package)
        }
        return nil
    }

    private static func lookUpCrate(_ names: [String]) async -> Match? {
        for name in names where !name.hasPrefix("@") && !name.contains("/") {
            guard let response = await fetchJSON("https://crates.io/api/v1/crates/\(name)"),
                  let crate = response["crate"] as? [String: Any],
                  let crateName = crate["name"] as? String else { continue }
            let newestVersion = crate["max_stable_version"] as? String ?? crate["newest_version"] as? String
            let versions = response["versions"] as? [[String: Any]] ?? []
            let versionInfo = versions.first { ($0["num"] as? String) == newestVersion } ?? versions.first
            let binaryNames = versionInfo?["bin_names"] as? [String] ?? []
            // crates.io lists which programs a crate builds; none means a library.
            guard !binaryNames.isEmpty else { continue }
            let package = DottieToolPackage(
                source: .cargo,
                packageName: crateName,
                title: crateName,
                summary: sentence(crate["description"] as? String),
                homepage: (crate["homepage"] as? String) ?? (crate["repository"] as? String),
                commands: binaryNames
            )
            return Match(package: package)
        }
        return nil
    }

    // MARK: - Helpers

    /// GETs a JSON object, or nil for anything but a 200.
    private static func fetchJSON(_ address: String) async -> [String: Any]? {
        guard let url = URL(string: address) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // crates.io asks every client to say who it is.
        request.setValue("Dottie (https://github.com/IamWasee/dottie)", forHTTPHeaderField: "User-Agent")
        guard let dataAndResponse = try? await URLSession.shared.data(for: request),
              (dataAndResponse.1 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: dataAndResponse.0) as? [String: Any]
    }

    /// A description as one short sentence with a capital and a full stop.
    private static func sentence(_ text: String?) -> String {
        var trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.count > 140 { trimmed = String(trimmed.prefix(137)) + "…" }
        trimmed = trimmed.prefix(1).uppercased() + trimmed.dropFirst()
        if let lastCharacter = trimmed.last, !".!?…".contains(lastCharacter) { trimmed += "." }
        return trimmed
    }
}
