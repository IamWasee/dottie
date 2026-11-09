import { defineConfig } from "vitest/config";

// Speed checks for the Worker's own code (no network). They run in plain
// Node, not the Workers runtime: workerd freezes its clock while code runs
// (a Spectre protection), so nothing can be timed inside it.
export default defineConfig({
  test: {
    include: ["test/performance/**/*.performance.ts"],
    environment: "node",
    fileParallelism: false,
  },
});
