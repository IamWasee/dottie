//
//  DottieMCPPresets.swift
//  leanring-buddy
//
//  One-click apps for Home → Tools. Each is a real, maintained MCP server
//  (package names checked on npm, PyPI and the makers' own docs). Servers
//  that run through npx use Dottie's own Node.js when the Mac has none;
//  ones that run through uvx need uv, which the Tools tab can install.
//
//  ${NAME} in a preset is filled in when the user adds it: keys and tokens
//  go to the Keychain, folders and addresses go straight into tools.json.
//

import Foundation

struct DottieMCPPreset: Identifiable {
    struct Field {
        enum Kind {
            /// A key or token: kept in the Keychain.
            case secret
            /// One or more folders the user picks; fills a whole argument.
            case folders
            case folder
            case file
            /// A web address, like http://homeassistant.local:8123.
            case address
        }

        let placeholder: String
        let label: String
        let kind: Kind
        var hint: String = ""
        var isOptional = false
    }

    let id: String
    let title: String
    let summary: String
    let symbolName: String
    let config: DottieMCPServerConfig
    var fields: [Field] = []
    /// Where to get the key, when it needs one.
    var keyLink: String?

    var needsKey: Bool { fields.contains { $0.kind == .secret && !$0.isOptional } }

    /// The program it runs with, for "needs uv" style hints.
    var launcher: String? { config.command }
}

enum DottieMCPPresets {
    private static var memoryFilePath: String {
        DottieToolsFile.folderURL.appendingPathComponent("memory-graph.jsonl").path
    }

    static var all: [DottieMCPPreset] {
        [
            // Files, web and code
            DottieMCPPreset(
                id: "filesystem", title: "Files and folders",
                summary: "Read, search and edit files in folders you pick.",
                symbolName: "folder",
                config: npx("@modelcontextprotocol/server-filesystem", extra: ["${FOLDERS}"]),
                fields: [.init(placeholder: "FOLDERS", label: "Folders it may use", kind: .folders)]
            ),
            DottieMCPPreset(
                id: "fetch", title: "Web pages",
                summary: "Reads any web page as clean text.",
                symbolName: "globe",
                config: uvx("mcp-server-fetch")
            ),
            DottieMCPPreset(
                id: "git", title: "Git",
                summary: "Looks through and works with the history of your code projects.",
                symbolName: "arrow.triangle.branch",
                config: uvx("mcp-server-git")
            ),
            DottieMCPPreset(
                id: "github", title: "GitHub",
                summary: "Issues, pull requests and code on GitHub.",
                symbolName: "chevron.left.forwardslash.chevron.right",
                config: web("https://api.githubcopilot.com/mcp/", token: "GITHUB_TOKEN"),
                fields: [.init(placeholder: "GITHUB_TOKEN", label: "GitHub token", kind: .secret, hint: "Filled in for you when you're signed in to the GitHub CLI (gh). Otherwise make a token with access to your repositories, private ones included.")],
                keyLink: "https://github.com/settings/personal-access-tokens/new"
            ),
            DottieMCPPreset(
                id: "playwright", title: "Web browser",
                summary: "Opens a browser and clicks around websites (Playwright).",
                symbolName: "safari",
                config: npx("@playwright/mcp@latest")
            ),
            DottieMCPPreset(
                id: "chrome", title: "Chrome",
                summary: "Drives and inspects Google Chrome (Chrome DevTools).",
                symbolName: "macwindow",
                config: npx("chrome-devtools-mcp@latest")
            ),
            DottieMCPPreset(
                id: "desktop-commander", title: "Desktop Commander",
                summary: "Runs Terminal commands and edits files anywhere on this Mac.",
                symbolName: "terminal",
                config: npx("@wonderwhy-er/desktop-commander@latest")
            ),
            DottieMCPPreset(
                id: "sqlite", title: "SQLite database",
                summary: "Looks inside a database file and answers questions about it.",
                symbolName: "cylinder.split.1x2",
                config: npx("mcp-sqlite", extra: ["${DATABASE}"]),
                fields: [.init(placeholder: "DATABASE", label: "Database file", kind: .file)]
            ),
            DottieMCPPreset(
                id: "context7", title: "Code docs",
                summary: "Up-to-date docs for programming libraries (Context7).",
                symbolName: "book",
                config: DottieMCPServerConfig(url: "https://mcp.context7.com/mcp")
            ),

            // Thinking and memory
            DottieMCPPreset(
                id: "sequential-thinking", title: "Step-by-step thinking",
                summary: "Helps work through hard problems one step at a time.",
                symbolName: "list.number",
                config: npx("@modelcontextprotocol/server-sequential-thinking")
            ),
            DottieMCPPreset(
                id: "memory", title: "Memory notebook",
                summary: "Remembers people, things and how they connect.",
                symbolName: "point.3.connected.trianglepath.dotted",
                config: npx("@modelcontextprotocol/server-memory", env: ["MEMORY_FILE_PATH": memoryFilePath])
            ),
            DottieMCPPreset(
                id: "time", title: "Time zones",
                summary: "The time anywhere, and converting between time zones.",
                symbolName: "clock",
                config: uvx("mcp-server-time")
            ),

            // Search and knowledge
            DottieMCPPreset(
                id: "exa", title: "Exa search",
                summary: "Searches the web. Free, no key needed.",
                symbolName: "magnifyingglass",
                config: DottieMCPServerConfig(url: "https://mcp.exa.ai/mcp")
            ),
            DottieMCPPreset(
                id: "brave-search", title: "Brave Search",
                summary: "Searches the web, news, images and places.",
                symbolName: "magnifyingglass.circle",
                config: npx("@brave/brave-search-mcp-server", extra: ["--transport", "stdio"], env: ["BRAVE_API_KEY": "${BRAVE_API_KEY}"]),
                fields: [.init(placeholder: "BRAVE_API_KEY", label: "Brave Search API key", kind: .secret, hint: "The free plan works.")],
                keyLink: "https://brave.com/search/api/"
            ),
            DottieMCPPreset(
                id: "tavily", title: "Tavily search",
                summary: "Web search and page reading made for AI.",
                symbolName: "sparkle.magnifyingglass",
                config: npx("tavily-mcp@latest", env: ["TAVILY_API_KEY": "${TAVILY_API_KEY}"]),
                fields: [.init(placeholder: "TAVILY_API_KEY", label: "Tavily API key", kind: .secret, hint: "The free plan works.")],
                keyLink: "https://app.tavily.com/home"
            ),
            DottieMCPPreset(
                id: "wikipedia", title: "Wikipedia",
                summary: "Looks things up on Wikipedia.",
                symbolName: "text.book.closed",
                config: uvx("wikipedia-mcp")
            ),
            DottieMCPPreset(
                id: "arxiv", title: "arXiv papers",
                summary: "Finds and reads science papers on arXiv.",
                symbolName: "doc.text.magnifyingglass",
                config: uvx("arxiv-mcp-server")
            ),
            DottieMCPPreset(
                id: "youtube", title: "YouTube transcripts",
                summary: "Gets what's said in a YouTube video, as text.",
                symbolName: "play.rectangle",
                config: npx("@sinco-lab/mcp-youtube-transcript")
            ),
            DottieMCPPreset(
                id: "aws-docs", title: "AWS docs",
                summary: "Answers from Amazon Web Services' own docs.",
                symbolName: "cloud",
                config: DottieMCPServerConfig(url: "https://knowledge-mcp.global.api.aws")
            ),
            DottieMCPPreset(
                id: "cloudflare-docs", title: "Cloudflare docs",
                summary: "Answers from Cloudflare's own docs.",
                symbolName: "cloud.fill",
                config: DottieMCPServerConfig(url: "https://docs.mcp.cloudflare.com/mcp")
            ),

            // Your apps and accounts
            DottieMCPPreset(
                id: "apple", title: "Apple apps",
                summary: "Messages, Notes, Mail, Contacts and Maps on this Mac.",
                symbolName: "applelogo",
                config: npx("apple-mcp")
            ),
            DottieMCPPreset(
                id: "apple-reminders", title: "Reminders and Calendar",
                summary: "Reads and adds reminders and calendar events on this Mac.",
                symbolName: "checklist",
                config: npx("mcp-server-apple-events")
            ),
            DottieMCPPreset(
                id: "google", title: "Gmail, Calendar and Drive",
                summary: "Your Google mail, calendar and files. Google asks you to sign in the first time.",
                symbolName: "envelope",
                config: uvx("workspace-mcp", extra: ["--tools", "gmail", "drive", "calendar"], env: [
                    "GOOGLE_OAUTH_CLIENT_ID": "${GOOGLE_OAUTH_CLIENT_ID}",
                    "GOOGLE_OAUTH_CLIENT_SECRET": "${GOOGLE_OAUTH_CLIENT_SECRET}",
                    "OAUTHLIB_INSECURE_TRANSPORT": "1"
                ]),
                fields: [
                    .init(placeholder: "GOOGLE_OAUTH_CLIENT_ID", label: "Google OAuth client ID", kind: .secret, hint: "In Google Cloud, make an OAuth client of type Desktop app."),
                    .init(placeholder: "GOOGLE_OAUTH_CLIENT_SECRET", label: "Google OAuth client secret", kind: .secret)
                ],
                keyLink: "https://console.cloud.google.com/apis/credentials"
            ),
            DottieMCPPreset(
                id: "notion", title: "Notion",
                summary: "Reads and writes your Notion pages and databases.",
                symbolName: "doc.richtext",
                config: npx("@notionhq/notion-mcp-server", env: ["NOTION_TOKEN": "${NOTION_TOKEN}"]),
                fields: [.init(placeholder: "NOTION_TOKEN", label: "Notion integration token", kind: .secret, hint: "Make an integration, then share the pages you want with it.")],
                keyLink: "https://www.notion.so/profile/integrations"
            ),
            DottieMCPPreset(
                id: "slack", title: "Slack",
                summary: "Reads and searches your Slack channels and messages.",
                symbolName: "number",
                config: npx("slack-mcp-server@latest", extra: ["--transport", "stdio"], env: ["SLACK_MCP_XOXP_TOKEN": "${SLACK_MCP_XOXP_TOKEN}"]),
                fields: [.init(placeholder: "SLACK_MCP_XOXP_TOKEN", label: "Slack user token", kind: .secret, hint: "Starts with xoxp-. Make a Slack app and copy its User OAuth Token.")],
                keyLink: "https://api.slack.com/apps"
            ),
            DottieMCPPreset(
                id: "linear", title: "Linear",
                summary: "Issues and projects in Linear.",
                symbolName: "line.3.horizontal.decrease",
                config: web("https://mcp.linear.app/mcp", token: "LINEAR_API_KEY"),
                fields: [.init(placeholder: "LINEAR_API_KEY", label: "Linear API key", kind: .secret)],
                keyLink: "https://linear.app/settings/account/security"
            ),
            DottieMCPPreset(
                id: "todoist", title: "Todoist",
                summary: "Your Todoist tasks and projects.",
                symbolName: "checkmark.circle",
                config: npx("@doist/todoist-mcp", env: ["TODOIST_API_KEY": "${TODOIST_API_KEY}"]),
                fields: [.init(placeholder: "TODOIST_API_KEY", label: "Todoist API token", kind: .secret)],
                keyLink: "https://app.todoist.com/app/settings/integrations/developer"
            ),
            DottieMCPPreset(
                id: "obsidian", title: "Obsidian",
                summary: "Reads and writes the notes in your Obsidian vault.",
                symbolName: "diamond",
                config: npx("obsidian-mcp@2", extra: ["serve", "--vault", "notes=${VAULT}"]),
                fields: [.init(placeholder: "VAULT", label: "Your vault folder", kind: .folder)]
            ),
            DottieMCPPreset(
                id: "home-assistant", title: "Home Assistant",
                summary: "Controls your smart home through Home Assistant.",
                symbolName: "house",
                config: DottieMCPServerConfig(url: "${HA_URL}/api/mcp", headers: ["Authorization": "Bearer ${HA_TOKEN}"]),
                fields: [
                    .init(placeholder: "HA_URL", label: "Home Assistant address", kind: .address, hint: "Like http://homeassistant.local:8123. Turn on the MCP Server integration in Home Assistant first."),
                    .init(placeholder: "HA_TOKEN", label: "Long-lived access token", kind: .secret, hint: "Your profile in Home Assistant → Security → Create token.")
                ]
            ),
            DottieMCPPreset(
                id: "figma", title: "Figma",
                summary: "Reads your Figma designs so helpers can build from them.",
                symbolName: "paintpalette",
                config: npx("figma-developer-mcp", extra: ["--stdio"], env: ["FIGMA_API_KEY": "${FIGMA_API_KEY}"]),
                fields: [.init(placeholder: "FIGMA_API_KEY", label: "Figma personal access token", kind: .secret, hint: "Figma → Settings → Security → Personal access tokens.")],
                keyLink: "https://www.figma.com/settings"
            ),

            // Developer services
            DottieMCPPreset(
                id: "stripe", title: "Stripe",
                summary: "Payments, customers and invoices in Stripe.",
                symbolName: "creditcard",
                config: npx("@stripe/mcp", env: ["STRIPE_SECRET_KEY": "${STRIPE_SECRET_KEY}"]),
                fields: [.init(placeholder: "STRIPE_SECRET_KEY", label: "Stripe secret key", kind: .secret, hint: "A restricted key is safest.")],
                keyLink: "https://dashboard.stripe.com/apikeys"
            ),
            DottieMCPPreset(
                id: "supabase", title: "Supabase",
                summary: "Your Supabase projects and databases.",
                symbolName: "bolt.horizontal",
                config: npx("@supabase/mcp-server-supabase@latest", env: ["SUPABASE_ACCESS_TOKEN": "${SUPABASE_ACCESS_TOKEN}"]),
                fields: [.init(placeholder: "SUPABASE_ACCESS_TOKEN", label: "Supabase access token", kind: .secret)],
                keyLink: "https://supabase.com/dashboard/account/tokens"
            ),
            DottieMCPPreset(
                id: "sentry", title: "Sentry",
                summary: "Errors and crashes from your apps in Sentry.",
                symbolName: "exclamationmark.triangle",
                config: npx("@sentry/mcp-server@latest", env: ["SENTRY_ACCESS_TOKEN": "${SENTRY_ACCESS_TOKEN}"]),
                fields: [.init(placeholder: "SENTRY_ACCESS_TOKEN", label: "Sentry auth token", kind: .secret)],
                keyLink: "https://sentry.io/settings/account/api/auth-tokens/"
            ),
            DottieMCPPreset(
                id: "docker", title: "Docker",
                summary: "Your Docker containers and images. Docker must be running.",
                symbolName: "shippingbox",
                config: uvx("mcp-server-docker")
            ),
            // Games
            DottieMCPPreset(
                id: "roblox-studio", title: "Roblox Studio",
                summary: "Builds and scripts your Roblox game in Studio: reads the place, adds parts, writes Luau, runs play tests. In Studio, open Assistant → … → Manage MCP Servers and turn on Enable Studio as MCP server.",
                symbolName: "gamecontroller",
                config: DottieMCPServerConfig(command: "/Applications/RobloxStudio.app/Contents/MacOS/StudioMCP")
            ),
            DottieMCPPreset(
                id: "kubernetes", title: "Kubernetes",
                summary: "Your Kubernetes clusters, using your kubectl setup.",
                symbolName: "circle.hexagongrid",
                config: npx("mcp-server-kubernetes")
            )
        ] + signInConnectors
    }

    /// Connectors like Claude's: the maker's own hosted server, signed into
    /// in the browser the first time it connects (OAuth), with no key to
    /// copy. Dottie reaches them through mcp-remote, which opens the
    /// sign-in page, keeps the sign-in in ~/.mcp-auth and speaks plain
    /// stdio to Dottie and her helpers. Addresses from each maker's docs,
    /// cross-checked against github.com/jaw9c/awesome-remote-mcp-servers
    /// (Oct 2026). GitHub isn't one: its hosted server doesn't let apps
    /// register for a browser sign-in, so mcp-remote's sign-in ends in a
    /// 404. GitHub uses a token instead (the "github" preset), taken from
    /// the GitHub CLI's sign-in when there is one.
    static var signInConnectors: [DottieMCPPreset] {
        [
            signIn("notion-connector", "Notion", "Pages and databases in your Notion.", "doc.richtext", "https://mcp.notion.com/mcp"),
            signIn("atlassian-connector", "Jira and Confluence", "Issues, boards and pages in Atlassian.", "square.stack.3d.up", "https://mcp.atlassian.com/v1/sse"),
            signIn("asana-connector", "Asana", "Your tasks and projects in Asana.", "checkmark.circle", "https://mcp.asana.com/sse"),
            signIn("linear-connector", "Linear", "Issues and projects in Linear.", "line.3.horizontal.decrease", "https://mcp.linear.app/sse"),
            signIn("monday-connector", "monday.com", "Boards and items in monday.com.", "calendar", "https://mcp.monday.com/sse"),
            signIn("airtable-connector", "Airtable", "Bases, tables and records in Airtable.", "tablecells", "https://mcp.airtable.com/mcp"),
            signIn("canva-connector", "Canva", "Make and edit designs in your Canva.", "paintbrush", "https://mcp.canva.com/mcp"),
            signIn("intercom-connector", "Intercom", "Conversations and customers in Intercom.", "bubble.left.and.bubble.right", "https://mcp.intercom.com/sse"),
            signIn("hubspot-connector", "HubSpot", "Contacts, companies and deals in HubSpot.", "person.2", "https://app.hubspot.com/mcp/v1/http"),
            signIn("attio-connector", "Attio", "Your CRM records in Attio.", "person.crop.rectangle.stack", "https://mcp.attio.com/mcp"),
            signIn("box-connector", "Box", "Files and folders in your Box.", "shippingbox", "https://mcp.box.com"),
            signIn("fireflies-connector", "Fireflies", "Meeting notes and transcripts from Fireflies.", "waveform", "https://api.fireflies.ai/mcp"),
            signIn("paypal-connector", "PayPal", "Invoices, orders and payments in PayPal. Dottie asks before paying anything.", "dollarsign.circle", "https://mcp.paypal.com/sse"),
            signIn("square-connector", "Square", "Orders, items and customers in Square.", "square", "https://mcp.squareup.com/sse"),
            signIn("stripe-connector", "Stripe", "Payments, customers and invoices in Stripe.", "creditcard", "https://mcp.stripe.com"),
            signIn("vercel-connector", "Vercel", "Your Vercel projects and deployments.", "triangle", "https://mcp.vercel.com"),
            signIn("netlify-connector", "Netlify", "Your Netlify sites and deploys.", "globe", "https://netlify-mcp.netlify.app/mcp"),
            signIn("cloudflare-connector", "Cloudflare", "Workers, storage and databases in your Cloudflare account.", "cloud", "https://bindings.mcp.cloudflare.com/sse"),
            signIn("supabase-connector", "Supabase", "Your Supabase projects and databases.", "bolt.horizontal", "https://mcp.supabase.com/mcp"),
            signIn("neon-connector", "Neon", "Your Neon Postgres databases.", "cylinder", "https://mcp.neon.tech/mcp"),
            signIn("sentry-connector", "Sentry", "Errors and crashes from your apps.", "exclamationmark.triangle", "https://mcp.sentry.dev/sse"),
            signIn("webflow-connector", "Webflow", "Your Webflow sites and CMS.", "w.square", "https://mcp.webflow.com/sse"),
            signIn("wix-connector", "Wix", "Your Wix sites, store and bookings.", "globe.americas", "https://mcp.wix.com/sse"),
            signIn("stackoverflow-connector", "Stack Overflow", "Search Stack Overflow questions and answers.", "text.bubble", "https://mcp.stackoverflow.com"),
            signIn("huggingface-connector", "Hugging Face", "Models, datasets and Spaces on Hugging Face.", "face.smiling", "https://hf.co/mcp"),
            signIn("deepwiki-connector", "DeepWiki", "Ask about any public GitHub repo's code.", "book", "https://mcp.deepwiki.com/sse")
        ]
    }

    private static func signIn(_ id: String, _ title: String, _ summary: String, _ symbolName: String, _ url: String) -> DottieMCPPreset {
        DottieMCPPreset(
            id: id,
            title: title,
            summary: summary + " Sign in once in your browser, no key needed.",
            symbolName: symbolName,
            config: DottieMCPServerConfig(command: "npx", args: ["-y", "mcp-remote@latest", url], env: [:])
        )
    }

    static func preset(withID presetID: String) -> DottieMCPPreset? {
        all.first { $0.id == presetID }
    }

    private static func npx(_ package: String, extra: [String] = [], env: [String: String] = [:]) -> DottieMCPServerConfig {
        DottieMCPServerConfig(command: "npx", args: ["-y", package] + extra, env: env)
    }

    private static func uvx(_ package: String, extra: [String] = [], env: [String: String] = [:]) -> DottieMCPServerConfig {
        DottieMCPServerConfig(command: "uvx", args: [package] + extra, env: env)
    }

    private static func web(_ url: String, token: String) -> DottieMCPServerConfig {
        DottieMCPServerConfig(url: url, headers: ["Authorization": "Bearer ${\(token)}"])
    }
}
