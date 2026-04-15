import fs from "node:fs/promises";
import { describe, expect, it, vi } from "vitest";
import type { OpenClawConfig } from "../../src/config/config.js";
import type { ContextEngineFactory } from "../../src/context-engine/registry.js";
import type { ContextEngine } from "../../src/context-engine/types.js";
import { buildPluginApi } from "../../src/plugins/api-builder.js";
import type { PluginRuntime } from "../../src/plugins/runtime/types.js";
import type { PluginLogger } from "../../src/plugins/types.js";
import guidancePlugin from "./index.js";

vi.mock("node:fs/promises");

const mockConfig = {} as unknown as OpenClawConfig;
const mockRuntime = {} as unknown as PluginRuntime;

function createMockLogger(): PluginLogger {
  return {
    info: vi.fn(),
    warn: vi.fn(),
    error: vi.fn(),
    debug: vi.fn(),
  };
}

describe("guidance context engine plugin", () => {
  it("registers a context engine named 'guidance'", async () => {
    let registeredEngine: ContextEngineFactory | undefined;
    const api = buildPluginApi({
      id: "test",
      name: "test",
      source: "test",
      registrationMode: "full",
      config: mockConfig,
      pluginConfig: { files: ["test.md"] },
      runtime: mockRuntime,
      logger: createMockLogger(),
      resolvePath: (p) => p,
      handlers: {
        registerContextEngine: (id, factory) => {
          if (id === "guidance") {
            registeredEngine = factory;
          }
        },
      },
    });

    await guidancePlugin.register(api);
    expect(registeredEngine).toBeDefined();

    const engine = await registeredEngine!();
    expect(engine.info.id).toBe("guidance");
  });

  it("injects guidance from files in assemble", async () => {
    const mockFiles = ["rules1.md", "rules2.md"];
    vi.mocked(fs.readFile).mockImplementation(async (path) => {
      if (path === "rules1.md") {
        return "Rule 1 content";
      }
      if (path === "rules2.md") {
        return "Rule 2 content";
      }
      throw new Error("File not found");
    });

    let registeredFactory: ContextEngineFactory | undefined;
    const api = buildPluginApi({
      id: "test",
      name: "test",
      source: "test",
      registrationMode: "full",
      config: mockConfig,
      pluginConfig: { files: mockFiles },
      runtime: mockRuntime,
      logger: createMockLogger(),
      resolvePath: (p: string) => p,
      handlers: {
        registerContextEngine: (_id, factory) => {
          registeredFactory = factory;
        },
      },
    });

    await guidancePlugin.register(api);
    const engine = await registeredFactory!();
    const result = await engine.assemble({
      sessionId: "test",
      messages: [],
      tokenBudget: 1000,
      model: "test-model",
    });

    expect(result.systemPromptAddition).toContain("Rule 1 content");
    expect(result.systemPromptAddition).toContain("Rule 2 content");
    expect(result.systemPromptAddition).toContain("\n\n");
  });

  it("resolves relative paths using api.resolvePath", async () => {
    const mockFiles = ["relative/rules.md"];
    vi.mocked(fs.readFile).mockImplementation(async (path) => {
      if (path === "/absolute/relative/rules.md") {
        return "Resolved content";
      }
      throw new Error("File not found");
    });

    let registeredFactory: ContextEngineFactory | undefined;
    const api = buildPluginApi({
      id: "test",
      name: "test",
      source: "test",
      registrationMode: "full",
      config: mockConfig,
      pluginConfig: { files: mockFiles },
      runtime: mockRuntime,
      logger: createMockLogger(),
      resolvePath: (p: string) => `/absolute/${p}`,
      handlers: {
        registerContextEngine: (_id, factory) => {
          registeredFactory = factory;
        },
      },
    });

    await guidancePlugin.register(api);
    const engine = await registeredFactory!();
    const result = await engine.assemble({
      sessionId: "test",
      messages: [],
      tokenBudget: 1000,
      model: "test-model",
    });

    expect(result.systemPromptAddition).toBe("Resolved content");
  });
});
