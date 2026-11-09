import { cloudflareTest } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

// Tests run inside the real Workers runtime (workerd, through Miniflare),
// with the Durable Object from wrangler.toml and made-up keys. Nothing here
// reaches Gemini, Groq, NVIDIA or Telegram: each test fakes `fetch`.
export default defineConfig({
  plugins: [
    cloudflareTest({
      wrangler: { configPath: "./wrangler.toml" },
      miniflare: {
        bindings: {
          GEMINI_API_KEY: "test-gemini-key",
        },
      },
    }),
  ],
  test: {
    include: ["test/**/*.test.ts"],
    coverage: {
      provider: "istanbul",
      include: ["src/**/*.ts"],
      reporter: ["text", "json-summary"],
      // The suite is at about 99% of lines and 96% of branches; a change that
      // drops below these fails CI until it comes with tests.
      thresholds: { lines: 97, functions: 97, branches: 93, statements: 97 },
    },
  },
});
