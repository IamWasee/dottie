---
name: secure-coding
description: Use when writing or checking code that handles user input, logins, files, databases, secrets or the web ("is this secure", "security audit", "check for vulnerabilities", building an API or web app).
---

# Secure Coding

## When to use

- Building anything that takes input from users, files, URLs or other programs.
- Code with accounts, sessions, payments, uploads, database queries or shell commands.
- The user asks for a security check, audit or "is this safe".

Do not use when:

- The user wants a general review covering style and performance too. Use code-review, and use this checklist for its security part.

## Steps

1. Map the attack surface: list every entry point (HTTP routes, CLI args, file readers, webhooks, message handlers) and every sensitive sink (database, shell, file system, HTML output, outbound requests, eval). Write it in `tmp/security-notes.md`.
2. Secrets out of code. Search for keys and passwords (see Tools). Secrets belong in environment variables or the platform's secret store, read at runtime; `.env` is listed in .gitignore and an `.env.example` holds names only. If a real secret was committed, tell the user to rotate it; deleting it from the file does not remove it from git history. Never ask for, copy or store the secret yourself.
3. Validate input at the boundary: check type, length, range and format with an allowlist (expected values) rather than a blocklist. Reject early with a clear error. Use a schema library where the project has one (zod, pydantic, Codable).
4. Injection, for each sink:
   - SQL: parameterized queries or the ORM's binding (`cursor.execute("... WHERE id = ?", (user_id,))`), never string formatting.
   - Shell: pass an argument list (`subprocess.run(["convert", path])`, `execFile`), never `shell=True` or `exec` with user text.
   - HTML: let the template engine escape; avoid `innerHTML`, `dangerouslySetInnerHTML`, `|safe` with user data.
   - Paths: resolve and confirm the result stays inside the allowed folder (block `../`).
   - Never `eval`, `pickle.loads`, or `yaml.load` (use `yaml.safe_load`) on untrusted data.
5. Auth and access control: every route that reads or changes private data checks who the user is and that they own that record (not just that they are logged in). Check on the server, never only in the UI. Deny by default.
6. Passwords and sessions: hash with bcrypt, scrypt or argon2, never plain SHA; cookies `HttpOnly`, `Secure`, `SameSite=Lax` or stricter; CSRF protection for cookie-based forms; rate-limit login.
7. Outbound requests built from user input (SSRF): allowlist hosts; block internal addresses like `127.0.0.1`, `169.254.169.254`, `10.x`.
8. Errors and logs: users see generic messages; logs never contain passwords, tokens or full card numbers.
9. Dependencies: run the audit for the stack and upgrade anything high or critical that has a fix.
10. Walk the OWASP Top 10 (2021) checklist: A01 broken access control, A02 crypto failures (TLS, hashing, no home-made crypto), A03 injection (including XSS), A04 insecure design (abuse cases, limits), A05 misconfiguration (debug off, default passwords, CORS not `*` with credentials, security headers), A06 vulnerable components, A07 auth failures, A08 integrity (unsigned updates, unsafe deserialization), A09 logging and monitoring gaps, A10 SSRF.
11. Write findings to `output/security-review.md`, each with severity (critical, high, medium, low), file:line, how it could be exploited in one line, and the fix. Fix only when the user asked for fixes.

## Tools on a Mac

- Secret search: `grep -rnEi '(api[_-]?key|secret|token|passw(or)?d|private[_-]?key)\s*[:=]' --exclude-dir={node_modules,.git,.venv} .` and `git log -p | grep -nEi 'BEGIN (RSA|OPENSSH) PRIVATE KEY|sk-[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}'`.
- Dedicated scanner: `brew install gitleaks`, then `gitleaks detect --source . --no-banner`.
- Node: `npm audit`, `npm audit --omit=dev --audit-level=high`; fix with `npm audit fix` (not `--force` without checking the changes).
- Python: `python3 -m pip install --user pip-audit bandit`, then `pip-audit -r requirements.txt` and `bandit -r src -ll`.
- Multi-language static checks: `python3 -m pip install --user semgrep`, then `semgrep --config auto .`.
- Headers on a running site: `curl -sI https://localhost:3000 | grep -iE 'content-security|strict-transport|x-frame|x-content-type'`.
- Open ports a local app exposes: `lsof -nP -iTCP -sTCP:LISTEN`.

## Quality checklist

- No secrets in code, config committed to git, logs or replies.
- Every entry point validates input; every sink uses safe APIs.
- Every private-data route checks ownership on the server.
- Dependency audit run and its result reported.
- Each OWASP item checked or marked not applicable.
- Findings have severity, location, exploit line and fix.

## Reply to the user

"Security review in output/security-review.md: <N> issues, <M> high or critical. The most urgent is <one line>." If a secret leaked: say plainly that they should rotate it now.

## Pitfalls

- Validating in the browser only; attackers call the API directly.
- Escaping input on the way in instead of output encoding for each context.
- Checking "is logged in" but not "owns this record" (IDOR).
- Running audit fix with `--force` and breaking the app with a major upgrade.
- Testing exploits against systems the user does not own. Only test locally or on their own setup, with their yes.
- Printing a found secret in full in the reply; show only the first few characters and the file.

Based on: VibeSec and agamm OWASP security skills
