import fs from "node:fs";
import path from "node:path";
import AjvPkg from "ajv";
import type { JsonSchemaObject } from "openclaw/plugin-sdk/config-schema";
import { describe, expect, it } from "vitest";
import {
  DEFAULT_WIKI_RENDER_MODE,
  DEFAULT_WIKI_SEARCH_BACKEND,
  DEFAULT_WIKI_SEARCH_CORPUS,
  DEFAULT_WIKI_VAULT_MODE,
  resolveAgentScopedConfig,
  resolveDefaultMemoryWikiVaultPath,
  resolveMemoryWikiConfig,
} from "./config.js";

function compileManifestConfigSchema() {
  const manifest = JSON.parse(
    fs.readFileSync(new URL("../openclaw.plugin.json", import.meta.url), "utf8"),
  ) as { configSchema: JsonSchemaObject };
  const Ajv = AjvPkg as unknown as new (opts?: object) => import("ajv").default;
  const ajv = new Ajv({ allErrors: true, strict: false, useDefaults: true });
  return ajv.compile(manifest.configSchema);
}

describe("resolveMemoryWikiConfig", () => {
  it("returns isolated defaults", () => {
    const config = resolveMemoryWikiConfig(undefined, { homedir: "/Users/tester" });

    expect(config.vaultMode).toBe(DEFAULT_WIKI_VAULT_MODE);
    expect(config.vault.renderMode).toBe(DEFAULT_WIKI_RENDER_MODE);
    expect(config.vault.path).toBe(resolveDefaultMemoryWikiVaultPath("/Users/tester"));
    expect(config.search.backend).toBe(DEFAULT_WIKI_SEARCH_BACKEND);
    expect(config.search.corpus).toBe(DEFAULT_WIKI_SEARCH_CORPUS);
    expect(config.context.includeCompiledDigestPrompt).toBe(false);
  });

  it("expands ~/ paths and preserves explicit modes", () => {
    const config = resolveMemoryWikiConfig(
      {
        vaultMode: "bridge",
        vault: {
          path: "~/vaults/wiki",
          renderMode: "obsidian",
        },
      },
      { homedir: "/Users/tester" },
    );

    expect(config.vaultMode).toBe("bridge");
    expect(config.vault.path).toBe(path.join("/Users/tester", "vaults", "wiki"));
    expect(config.vault.renderMode).toBe("obsidian");
  });

  it("normalizes the bridge artifact toggle", () => {
    const canonical = resolveMemoryWikiConfig({
      bridge: {
        readMemoryArtifacts: false,
      },
    });

    expect(canonical.bridge.readMemoryArtifacts).toBe(false);
  });

  it("defaults perAgent to false", () => {
    const config = resolveMemoryWikiConfig(undefined, { homedir: "/Users/tester" });
    expect(config.vault.perAgent).toBe(false);
  });

  it("preserves perAgent when explicitly set to true", () => {
    const config = resolveMemoryWikiConfig(
      { vault: { perAgent: true } },
      { homedir: "/Users/tester" },
    );
    expect(config.vault.perAgent).toBe(true);
  });
});

describe("resolveAgentScopedConfig", () => {
  it("returns the same config when perAgent is false", () => {
    const config = resolveMemoryWikiConfig(
      { vault: { path: "/base/wiki", perAgent: false } },
      { homedir: "/Users/tester" },
    );
    const scoped = resolveAgentScopedConfig(config, "agent-1");
    expect(scoped.vault.path).toBe("/base/wiki");
    expect(scoped).toBe(config);
  });

  it("returns the same config when perAgent is true but agentId is absent", () => {
    const config = resolveMemoryWikiConfig(
      { vault: { path: "/base/wiki", perAgent: true } },
      { homedir: "/Users/tester" },
    );
    const scoped = resolveAgentScopedConfig(config, undefined);
    expect(scoped.vault.path).toBe("/base/wiki");
    expect(scoped).toBe(config);
  });

  it("returns the same config when perAgent is true but agentId is empty string", () => {
    const config = resolveMemoryWikiConfig(
      { vault: { path: "/base/wiki", perAgent: true } },
      { homedir: "/Users/tester" },
    );
    const scoped = resolveAgentScopedConfig(config, "   ");
    expect(scoped.vault.path).toBe("/base/wiki");
    expect(scoped).toBe(config);
  });

  it("scopes vault.path when perAgent is true and agentId is provided", () => {
    const config = resolveMemoryWikiConfig(
      { vault: { path: "/base/wiki", perAgent: true } },
      { homedir: "/Users/tester" },
    );
    const scoped = resolveAgentScopedConfig(config, "agent-1");
    expect(scoped.vault.path).toBe(path.join("/base/wiki", "agent-1"));
    expect(scoped.vault.perAgent).toBe(true);
    expect(scoped.vaultMode).toBe(config.vaultMode);
  });

  it("scopes vault.path for bridge mode when perAgent is true", () => {
    const config = resolveMemoryWikiConfig(
      { vaultMode: "bridge", vault: { path: "/base/wiki", perAgent: true } },
      { homedir: "/Users/tester" },
    );
    const scoped = resolveAgentScopedConfig(config, "bridge-agent");
    expect(scoped.vault.path).toBe(path.join("/base/wiki", "bridge-agent"));
    expect(scoped.vaultMode).toBe("bridge");
  });

  it("scopes vault.path for unsafe-local mode when perAgent is true", () => {
    const config = resolveMemoryWikiConfig(
      { vaultMode: "unsafe-local", vault: { path: "/base/wiki", perAgent: true } },
      { homedir: "/Users/tester" },
    );
    const scoped = resolveAgentScopedConfig(config, "local-agent");
    expect(scoped.vault.path).toBe(path.join("/base/wiki", "local-agent"));
    expect(scoped.vaultMode).toBe("unsafe-local");
  });

  it("trims whitespace from agentId", () => {
    const config = resolveMemoryWikiConfig(
      { vault: { path: "/base/wiki", perAgent: true } },
      { homedir: "/Users/tester" },
    );
    const scoped = resolveAgentScopedConfig(config, "  agent-2  ");
    expect(scoped.vault.path).toBe(path.join("/base/wiki", "agent-2"));
  });
});

describe("memory-wiki manifest config schema", () => {
  it("accepts the documented config shape", () => {
    const validate = compileManifestConfigSchema();
    const config = {
      vaultMode: "unsafe-local",
      vault: {
        path: "~/wiki",
        perAgent: true,
        renderMode: "obsidian",
      },
      obsidian: {
        enabled: true,
        useOfficialCli: true,
      },
      bridge: {
        enabled: true,
        readMemoryArtifacts: true,
        followMemoryEvents: true,
      },
      unsafeLocal: {
        allowPrivateMemoryCoreAccess: true,
        paths: ["extensions/memory-core/src"],
      },
      search: {
        backend: "shared",
        corpus: "all",
      },
      context: {
        includeCompiledDigestPrompt: true,
      },
    };

    expect(validate(config)).toBe(true);
  });
});
