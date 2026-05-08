import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { Command } from "commander";
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import {
  registerWikiCli,
  runWikiBridgeImport,
  runWikiChatGptImport,
  runWikiChatGptRollback,
  runWikiDoctor,
  runWikiStatus,
} from "./cli.js";
import type { MemoryWikiPluginConfig } from "./config.js";
import { resolveMemoryWikiConfig } from "./config.js";
import { parseWikiMarkdown, renderWikiMarkdown } from "./markdown.js";
import type { MemoryWikiDoctorReport, MemoryWikiStatus } from "./status.js";
import { createMemoryWikiTestHarness } from "./test-helpers.js";

const callGatewayFromCliMock = vi.hoisted(() => vi.fn());

vi.mock("openclaw/plugin-sdk/gateway-runtime", () => ({
  callGatewayFromCli: callGatewayFromCliMock,
}));

const { createVault } = createMemoryWikiTestHarness();
let suiteRoot = "";
let caseIndex = 0;

describe("memory-wiki cli", () => {
  beforeAll(async () => {
    suiteRoot = await fs.mkdtemp(path.join(os.tmpdir(), "memory-wiki-cli-suite-"));
  });

  afterAll(async () => {
    if (suiteRoot) {
      await fs.rm(suiteRoot, { recursive: true, force: true });
    }
  });

  beforeEach(() => {
    callGatewayFromCliMock.mockReset();
    vi.spyOn(process.stdout, "write").mockImplementation(
      (() => true) as typeof process.stdout.write,
    );
    process.exitCode = undefined;
  });

  afterEach(() => {
    vi.restoreAllMocks();
    process.exitCode = undefined;
  });

  async function createCliVault(options?: {
    config?: MemoryWikiPluginConfig;
    initialize?: boolean;
  }) {
    return createVault({
      prefix: "memory-wiki-cli-",
      rootDir: path.join(suiteRoot, `case-${caseIndex++}`),
      initialize: options?.initialize,
      config: options?.config,
    });
  }

  async function createChatGptExport(rootDir: string) {
    const exportDir = path.join(rootDir, "chatgpt-export");
    await fs.mkdir(exportDir, { recursive: true });
    const conversations = [
      {
        conversation_id: "12345678-1234-1234-1234-1234567890ab",
        title: "Travel preference check",
        create_time: 1_712_363_200,
        update_time: 1_712_366_800,
        current_node: "assistant-1",
        mapping: {
          root: {},
          "user-1": {
            parent: "root",
            message: {
              author: { role: "user" },
              content: {
                parts: ["I prefer aisle seats and I don't want a hotel far from the airport."],
              },
            },
          },
          "assistant-1": {
            parent: "user-1",
            message: {
              author: { role: "assistant" },
              content: {
                parts: ["Noted. I will keep travel options close to the airport."],
              },
            },
          },
        },
      },
    ];
    await fs.writeFile(
      path.join(exportDir, "conversations.json"),
      `${JSON.stringify(conversations, null, 2)}\n`,
      "utf8",
    );
    return exportDir;
  }

  function createGatewayStatus(config: {
    vault: { path: string };
    bridge: MemoryWikiStatus["bridge"];
  }): MemoryWikiStatus {
    return {
      vaultMode: "bridge",
      renderMode: "native",
      vaultPath: config.vault.path,
      vaultExists: true,
      bridge: config.bridge,
      bridgePublicArtifactCount: 2,
      obsidianCli: {
        enabled: false,
        requested: false,
        available: false,
        command: null,
      },
      unsafeLocal: {
        allowPrivateMemoryCoreAccess: false,
        pathCount: 0,
      },
      pageCounts: {
        source: 0,
        entity: 0,
        concept: 0,
        synthesis: 0,
        report: 0,
      },
      sourceCounts: {
        native: 0,
        bridge: 0,
        bridgeEvents: 0,
        unsafeLocal: 0,
        other: 0,
      },
      warnings: [],
    };
  }

  it("registers apply synthesis and writes a synthesis page", async () => {
    const { rootDir, config } = await createCliVault();
    const program = new Command();
    program.name("test");
    registerWikiCli(program, config);

    await program.parseAsync(
      [
        "wiki",
        "apply",
        "synthesis",
        "CLI Alpha",
        "--body",
        "Alpha from CLI.",
        "--source-id",
        "source.alpha",
        "--source-id",
        "source.beta",
      ],
      { from: "user" },
    );

    const page = await fs.readFile(path.join(rootDir, "syntheses", "cli-alpha.md"), "utf8");
    expect(page).toContain("Alpha from CLI.");
    expect(page).toContain("source.alpha");
    await expect(fs.readFile(path.join(rootDir, "index.md"), "utf8")).resolves.toContain(
      "[CLI Alpha](syntheses/cli-alpha.md)",
    );
  });

  it("registers apply metadata and preserves the page body", async () => {
    const { rootDir, config } = await createCliVault();
    const targetPath = path.join(rootDir, "entities", "alpha.md");
    await fs.mkdir(path.dirname(targetPath), { recursive: true });
    await fs.writeFile(
      targetPath,
      renderWikiMarkdown({
        frontmatter: {
          pageType: "entity",
          id: "entity.alpha",
          title: "Alpha",
          sourceIds: ["source.old"],
          confidence: 0.2,
        },
        body: `# Alpha

## Notes
<!-- openclaw:human:start -->
cli note
<!-- openclaw:human:end -->
`,
      }),
      "utf8",
    );

    const program = new Command();
    program.name("test");
    registerWikiCli(program, config);

    await program.parseAsync(
      [
        "wiki",
        "apply",
        "metadata",
        "entity.alpha",
        "--source-id",
        "source.new",
        "--contradiction",
        "Conflicts with source.beta",
        "--question",
        "Still active?",
        "--status",
        "review",
        "--clear-confidence",
      ],
      { from: "user" },
    );

    const page = await fs.readFile(path.join(rootDir, "entities", "alpha.md"), "utf8");
    const parsed = parseWikiMarkdown(page);
    expect(parsed.frontmatter).toMatchObject({
      sourceIds: ["source.new"],
      contradictions: ["Conflicts with source.beta"],
      questions: ["Still active?"],
      status: "review",
    });
    expect(parsed.frontmatter).not.toHaveProperty("confidence");
    expect(parsed.body).toContain("cli note");
  });

  it("runs wiki doctor and sets a non-zero exit code when warnings exist", async () => {
    const { rootDir, config } = await createCliVault({
      config: {
        vaultMode: "bridge",
        bridge: { enabled: false },
      },
    });
    const program = new Command();
    program.name("test");
    registerWikiCli(program, config);
    await fs.rm(rootDir, { recursive: true, force: true });

    await program.parseAsync(["wiki", "doctor", "--json"], { from: "user" });

    expect(process.exitCode).toBe(1);
    expect(callGatewayFromCliMock).not.toHaveBeenCalled();
  });

  it("routes active bridge status and doctor through the gateway", async () => {
    const { config } = await createCliVault({
      config: {
        vaultMode: "bridge",
        bridge: { enabled: true, readMemoryArtifacts: true },
      },
      initialize: true,
    });
    const status = createGatewayStatus(config);
    const report: MemoryWikiDoctorReport = {
      healthy: false,
      warningCount: 1,
      status: {
        ...status,
        warnings: [
          {
            code: "bridge-artifacts-missing",
            message: "No exported artifacts.",
          },
        ],
      },
      fixes: [
        {
          code: "bridge-artifacts-missing",
          message: "Create memory artifacts.",
        },
      ],
    };
    callGatewayFromCliMock.mockResolvedValueOnce(status).mockResolvedValueOnce(report);

    await expect(runWikiStatus({ config, json: true })).resolves.toBe(status);
    await expect(runWikiDoctor({ config, json: true })).resolves.toBe(report);

    expect(process.exitCode).toBe(1);
    expect(callGatewayFromCliMock).toHaveBeenNthCalledWith(
      1,
      "wiki.status",
      { timeout: "30000" },
      undefined,
      { progress: false },
    );
    expect(callGatewayFromCliMock).toHaveBeenNthCalledWith(
      2,
      "wiki.doctor",
      { timeout: "30000" },
      undefined,
      { progress: false },
    );
  });

  it("forwards agent to gateway-routed bridge commands", async () => {
    const { config } = await createCliVault({
      config: {
        vaultMode: "bridge",
        bridge: { enabled: true, readMemoryArtifacts: true },
      },
      initialize: true,
    });
    const status = createGatewayStatus(config);
    const report: MemoryWikiDoctorReport = {
      healthy: true,
      warningCount: 0,
      status,
      fixes: [],
    };
    callGatewayFromCliMock.mockResolvedValueOnce(status).mockResolvedValueOnce(report);

    await expect(runWikiStatus({ config, agent: "planner", json: true })).resolves.toBe(status);
    await expect(runWikiDoctor({ config, agent: "planner", json: true })).resolves.toBe(report);

    expect(callGatewayFromCliMock).toHaveBeenNthCalledWith(
      1,
      "wiki.status",
      { timeout: "30000" },
      { agent: "planner" },
      { progress: false },
    );
    expect(callGatewayFromCliMock).toHaveBeenNthCalledWith(
      2,
      "wiki.doctor",
      { timeout: "30000" },
      { agent: "planner" },
      { progress: false },
    );
  });

  it("sanitizes gateway status text output without changing JSON output", async () => {
    const { config } = await createCliVault({
      config: {
        vaultMode: "bridge",
        bridge: { enabled: true, readMemoryArtifacts: true },
      },
      initialize: true,
    });
    const unsafeStatus = createGatewayStatus({
      ...config,
      vault: { path: "\u001B[2J/tmp/wiki\nforged prompt\u202E" },
    });
    unsafeStatus.warnings = [
      {
        code: "bridge-artifacts-missing",
        message: "missing artifacts\r\nfake success\u001B[31m\u202E",
      },
    ];
    const textOutput: string[] = [];
    callGatewayFromCliMock.mockResolvedValueOnce(unsafeStatus);

    await runWikiStatus({
      config,
      stdout: {
        write: ((chunk: string) => textOutput.push(chunk) > 0) as NodeJS.WriteStream["write"],
      },
    });

    const renderedText = textOutput.join("");
    expect(renderedText).not.toContain("\u001B");
    expect(renderedText).not.toContain("\u202E");
    expect(renderedText).toContain("(/tmp/wiki forged prompt)");
    expect(renderedText).toContain("- missing artifacts fake success");

    const jsonOutput: string[] = [];
    callGatewayFromCliMock.mockResolvedValueOnce(unsafeStatus);

    await runWikiStatus({
      config,
      json: true,
      stdout: {
        write: ((chunk: string) => jsonOutput.push(chunk) > 0) as NodeJS.WriteStream["write"],
      },
    });

    const renderedJson = jsonOutput.join("");
    expect(renderedJson).not.toContain("\u001B");
    expect(renderedJson).not.toContain("\u202E");
    expect(renderedJson).not.toContain("\r");
    expect(renderedJson).toContain("\\u001b[2J/tmp/wiki\\nforged prompt\\u202e");
    expect(renderedJson).toContain("missing artifacts\\r\\nfake success\\u001b[31m\\u202e");

    const parsed = JSON.parse(renderedJson) as MemoryWikiStatus;
    expect(parsed.vaultPath).toBe("\u001B[2J/tmp/wiki\nforged prompt\u202E");
    expect(parsed.warnings[0]?.message).toBe("missing artifacts\r\nfake success\u001B[31m\u202E");
  });

  it("rejects malformed gateway responses before rendering", async () => {
    const { config } = await createCliVault({
      config: {
        vaultMode: "bridge",
        bridge: { enabled: true, readMemoryArtifacts: true },
      },
      initialize: true,
    });
    callGatewayFromCliMock.mockResolvedValueOnce({ vaultMode: "bridge" });

    await expect(runWikiStatus({ config })).rejects.toThrow(
      "Invalid Gateway response for wiki.status.",
    );
  });

  it("rejects oversized gateway strings before rendering", async () => {
    const { config } = await createCliVault({
      config: {
        vaultMode: "bridge",
        bridge: { enabled: true, readMemoryArtifacts: true },
      },
      initialize: true,
    });
    const status = createGatewayStatus(config);
    status.warnings = [
      {
        code: "bridge-artifacts-missing",
        message: "x".repeat(10_001),
      },
    ];
    callGatewayFromCliMock.mockResolvedValueOnce(status);

    await expect(runWikiStatus({ config })).rejects.toThrow(
      "Invalid Gateway response for wiki.status.",
    );
  });

  it("truncates gateway status text output after rendering", async () => {
    const { config } = await createCliVault({
      config: {
        vaultMode: "bridge",
        bridge: { enabled: true, readMemoryArtifacts: true },
      },
      initialize: true,
    });
    const status = createGatewayStatus(config);
    status.warnings = [
      {
        code: "bridge-artifacts-missing",
        message: `${"warning ".repeat(500)}tail`,
      },
    ];
    const textOutput: string[] = [];
    callGatewayFromCliMock.mockResolvedValueOnce(status);

    await runWikiStatus({
      config,
      stdout: {
        write: ((chunk: string) => textOutput.push(chunk) > 0) as NodeJS.WriteStream["write"],
      },
    });

    const renderedText = textOutput.join("");
    expect(renderedText).toContain("... [truncated]");
    expect(renderedText).not.toContain("tail");
  });

  it("routes active bridge imports through the gateway and keeps disabled bridge imports local", async () => {
    const active = await createCliVault({
      config: {
        vaultMode: "bridge",
        bridge: { enabled: true, readMemoryArtifacts: true },
      },
      initialize: true,
    });
    callGatewayFromCliMock.mockResolvedValueOnce({
      importedCount: 1,
      updatedCount: 0,
      skippedCount: 0,
      removedCount: 0,
      artifactCount: 1,
      workspaces: 1,
      pagePaths: ["sources/bridge-alpha.md"],
      indexesRefreshed: true,
      indexUpdatedFiles: ["index.md"],
      indexRefreshReason: "import-changed",
    });

    const activeResult = await runWikiBridgeImport({ config: active.config, json: true });

    expect(activeResult.importedCount).toBe(1);
    expect(callGatewayFromCliMock).toHaveBeenCalledWith(
      "wiki.bridge.import",
      { timeout: "30000" },
      undefined,
      { progress: false },
    );

    callGatewayFromCliMock.mockClear();
    const disabled = await createCliVault({
      config: {
        vaultMode: "bridge",
        bridge: { enabled: false },
      },
    });

    const disabledResult = await runWikiBridgeImport({ config: disabled.config, json: true });

    expect(disabledResult.artifactCount).toBe(0);
    expect(callGatewayFromCliMock).not.toHaveBeenCalled();
  });

  it("imports ChatGPT exports with dry-run, apply, and rollback", async () => {
    const { rootDir, config } = await createCliVault({ initialize: true });
    const exportDir = await createChatGptExport(rootDir);

    const dryRun = await runWikiChatGptImport({
      config,
      exportPath: exportDir,
      dryRun: true,
      json: true,
    });
    expect(dryRun.dryRun).toBe(true);
    expect(dryRun.createdCount).toBe(1);
    await expect(fs.readdir(path.join(rootDir, "sources"))).resolves.toEqual([]);

    const applied = await runWikiChatGptImport({
      config,
      exportPath: exportDir,
      json: true,
    });
    expect(applied.runId).toBeTruthy();
    expect(applied.createdCount).toBe(1);
    const sourceFiles = (await fs.readdir(path.join(rootDir, "sources"))).filter(
      (entry) => entry !== "index.md",
    );
    expect(sourceFiles).toHaveLength(1);
    const pageContent = await fs.readFile(path.join(rootDir, "sources", sourceFiles[0]), "utf8");
    expect(pageContent).toContain("ChatGPT Export: Travel preference check");
    expect(pageContent).toContain("I prefer aisle seats");
    expect(pageContent).toContain("Preference signals:");

    const secondDryRun = await runWikiChatGptImport({
      config,
      exportPath: exportDir,
      dryRun: true,
      json: true,
    });
    expect(secondDryRun.createdCount).toBe(0);
    expect(secondDryRun.updatedCount).toBe(0);
    expect(secondDryRun.skippedCount).toBe(1);

    const rollback = await runWikiChatGptRollback({
      config,
      runId: applied.runId!,
      json: true,
    });
    expect(rollback.alreadyRolledBack).toBe(false);
    await expect(
      fs
        .readdir(path.join(rootDir, "sources"))
        .then((entries) => entries.filter((entry) => entry !== "index.md")),
    ).resolves.toEqual([]);
  });

  describe("perAgent vault scoping", () => {
    it("uses base vault path when perAgent is false even if --agent is passed", async () => {
      const { rootDir, config } = await createCliVault({
        config: { vault: { perAgent: false } },
      });
      const program = new Command();
      program.name("test");
      registerWikiCli(program, config);

      await program.parseAsync(["wiki", "init", "--agent", "agent-1", "--json"], { from: "user" });

      // vault initialized at base path, NOT at base/agent-1
      await expect(fs.stat(rootDir)).resolves.toBeTruthy();
      await expect(fs.stat(path.join(rootDir, "agent-1"))).rejects.toThrow();
    });

    it("scopes vault path to <base>/<agentId> when perAgent is true (isolated mode)", async () => {
      const { rootDir, config } = await createCliVault({
        config: { vault: { perAgent: true } },
      });
      const program = new Command();
      program.name("test");
      registerWikiCli(program, config);

      await program.parseAsync(["wiki", "init", "--agent", "agent-alpha", "--json"], {
        from: "user",
      });

      const agentVaultDir = path.join(rootDir, "agent-alpha");
      await expect(fs.stat(agentVaultDir)).resolves.toBeTruthy();
      await expect(fs.readFile(path.join(agentVaultDir, "AGENTS.md"), "utf8")).resolves.toContain(
        "Memory Wiki Agent Guide",
      );
      // base vault should NOT be initialized
      await expect(fs.stat(path.join(rootDir, "AGENTS.md"))).rejects.toThrow();
    });

    it("falls back to base vault when perAgent is true but --agent is omitted", async () => {
      const { rootDir, config } = await createCliVault({
        config: { vault: { perAgent: true } },
      });
      const program = new Command();
      program.name("test");
      registerWikiCli(program, config);

      await program.parseAsync(["wiki", "init", "--json"], { from: "user" });

      // vault initialized at base path since no --agent given
      await expect(fs.stat(path.join(rootDir, "AGENTS.md"))).resolves.toBeTruthy();
    });

    it("scopes vault path for bridge mode when perAgent is true", async () => {
      const { rootDir, config } = await createCliVault({
        config: {
          vaultMode: "bridge",
          bridge: { enabled: false },
          vault: { perAgent: true },
        },
      });
      const program = new Command();
      program.name("test");
      registerWikiCli(program, config);

      await program.parseAsync(["wiki", "init", "--agent", "bridge-agent", "--json"], {
        from: "user",
      });

      await expect(fs.stat(path.join(rootDir, "bridge-agent", "AGENTS.md"))).resolves.toBeTruthy();
    });

    it("forwards --agent to gateway status in bridge mode", async () => {
      const { config } = await createCliVault({
        config: {
          vaultMode: "bridge",
          bridge: { enabled: true, readMemoryArtifacts: true },
          vault: { perAgent: true },
        },
        initialize: true,
      });
      const program = new Command();
      program.name("test");
      registerWikiCli(program, config);

      callGatewayFromCliMock.mockResolvedValueOnce(createGatewayStatus(config));

      await program.parseAsync(["wiki", "status", "--agent", "bridge-agent", "--json"], {
        from: "user",
      });

      expect(callGatewayFromCliMock).toHaveBeenCalledWith(
        "wiki.status",
        { timeout: "30000" },
        { agent: "bridge-agent" },
        { progress: false },
      );
    });

    it("scopes vault path for unsafe-local mode when perAgent is true", async () => {
      const { rootDir, config } = await createCliVault({
        config: {
          vaultMode: "unsafe-local",
          vault: { perAgent: true },
        },
      });
      const program = new Command();
      program.name("test");
      registerWikiCli(program, config);

      await program.parseAsync(["wiki", "init", "--agent", "local-agent", "--json"], {
        from: "user",
      });

      await expect(fs.stat(path.join(rootDir, "local-agent", "AGENTS.md"))).resolves.toBeTruthy();
    });

    it("obsidian status does not accept --agent", () => {
      const { config } = createVault;
      const program = new Command();
      program.name("test");
      program.exitOverride();
      const baseConfig = resolveMemoryWikiConfig({ vault: { perAgent: true } });
      registerWikiCli(program, baseConfig);

      // --agent on obsidian status should be unknown option → Commander throws
      expect(() =>
        program.parseSync(["wiki", "obsidian", "status", "--agent", "any-id"], { from: "user" }),
      ).toThrow();
    });

    it("applies synthesis to agent-scoped vault when perAgent is true", async () => {
      const { rootDir, config } = await createCliVault({
        config: { vault: { perAgent: true } },
      });
      const agentRootDir = path.join(rootDir, "agent-synth");
      // pre-init the agent vault
      const program = new Command();
      program.name("test");
      registerWikiCli(program, config);
      await program.parseAsync(["wiki", "init", "--agent", "agent-synth", "--json"], {
        from: "user",
      });

      await program.parseAsync(
        [
          "wiki",
          "apply",
          "synthesis",
          "PerAgent Synth",
          "--body",
          "Per-agent body.",
          "--source-id",
          "source.pa",
          "--agent",
          "agent-synth",
        ],
        { from: "user" },
      );

      await expect(
        fs.readFile(path.join(agentRootDir, "syntheses", "peragent-synth.md"), "utf8"),
      ).resolves.toContain("Per-agent body.");
      // the base vault should NOT have the synthesis
      await expect(fs.stat(path.join(rootDir, "syntheses", "peragent-synth.md"))).rejects.toThrow();
    });
  });
});
