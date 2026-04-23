import { describe, expect, it, vi } from "vitest";
import type { OpenClawConfig } from "../../src/config/config.js";
import type { ContextEngineFactory } from "../../src/context-engine/registry.js";
import { buildPluginApi } from "../../src/plugins/api-builder.js";
import type { PluginRuntime } from "../../src/plugins/runtime/types.js";
import type { PluginLogger } from "../../src/plugins/types.js";
import guidancePlugin from "./index.js";

const { mockOpenFileWithinRoot } = vi.hoisted(() => ({
  mockOpenFileWithinRoot: vi.fn(),
}));

vi.mock("openclaw/plugin-sdk/browser-support", () => ({
  CONFIG_DIR: "/home/node/.openclaw",
  openFileWithinRoot: mockOpenFileWithinRoot,
}));

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

function createOpenedFileResult(content: string, realPath: string) {
  return {
    handle: {
      readFile: vi.fn(async () => content),
      close: vi.fn(async () => undefined),
    },
    realPath,
    stat: { nlink: 1 },
  };
}

describe("guidance context engine plugin", () => {
  it("registers a context engine named 'guidance'", async () => {
    mockOpenFileWithinRoot.mockReset();
    let registeredEngine: ContextEngineFactory;
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
    mockOpenFileWithinRoot.mockReset();
    const mockFiles = ["rules1.md", "rules2.md"];
    mockOpenFileWithinRoot.mockImplementation(async ({ relativePath }) => {
      if (relativePath === "rules1.md") {
        return createOpenedFileResult("Rule 1 content", "/home/node/.openclaw/rules1.md");
      }
      if (relativePath === "rules2.md") {
        return createOpenedFileResult("Rule 2 content", "/home/node/.openclaw/rules2.md");
      }
      throw new Error("File not found");
    });

    let registeredFactory: ContextEngineFactory;
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

  it("reads relative paths under OpenClaw workspace root", async () => {
    mockOpenFileWithinRoot.mockReset();
    const mockFiles = ["workspace-shared/rules.md"];
    mockOpenFileWithinRoot.mockImplementation(async ({ relativePath }) => {
      if (relativePath === "workspace-shared/rules.md") {
        return createOpenedFileResult(
          "Resolved content",
          "/home/node/.openclaw/workspace-shared/rules.md",
        );
      }
      throw new Error("File not found");
    });

    let registeredFactory: ContextEngineFactory;
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
    expect(mockOpenFileWithinRoot).toHaveBeenCalledWith({
      rootDir: "/home/node/.openclaw",
      relativePath: "workspace-shared/rules.md",
      rejectHardlinks: true,
    });
  });

  it("allows absolute paths under OpenClaw workspace root", async () => {
    mockOpenFileWithinRoot.mockReset();
    const absolutePath = "/home/node/.openclaw/workspace-shared/AGENTS.md";
    mockOpenFileWithinRoot.mockImplementation(async ({ relativePath }) => {
      if (relativePath === "workspace-shared/AGENTS.md") {
        return createOpenedFileResult("Agent rules", absolutePath);
      }
      throw new Error("File not found");
    });

    let registeredFactory: ContextEngineFactory;
    const api = buildPluginApi({
      id: "test",
      name: "test",
      source: "test",
      registrationMode: "full",
      config: mockConfig,
      pluginConfig: { files: [absolutePath] },
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

    expect(result.systemPromptAddition).toBe("Agent rules");
    expect(mockOpenFileWithinRoot).toHaveBeenCalledWith({
      rootDir: "/home/node/.openclaw",
      relativePath: "workspace-shared/AGENTS.md",
      rejectHardlinks: true,
    });
  });

  it("rejects absolute paths outside OpenClaw workspace root", async () => {
    mockOpenFileWithinRoot.mockReset();
    mockOpenFileWithinRoot.mockRejectedValueOnce(new Error("file is outside workspace root"));

    let registeredFactory: ContextEngineFactory;
    const logger = createMockLogger();
    const blockedPath = "/etc/passwd";
    const api = buildPluginApi({
      id: "test",
      name: "test",
      source: "test",
      registrationMode: "full",
      config: mockConfig,
      pluginConfig: { files: [blockedPath] },
      runtime: mockRuntime,
      logger,
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

    expect(result.systemPromptAddition).toBe("");
    expect(logger.error).toHaveBeenCalledWith(
      expect.stringContaining("failed to read file /etc/passwd"),
    );
  });
});
