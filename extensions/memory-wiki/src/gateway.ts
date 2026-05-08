import { formatErrorMessage } from "openclaw/plugin-sdk/error-runtime";
import type { OpenClawConfig, OpenClawPluginApi } from "../api.js";
import { applyMemoryWikiMutation, normalizeMemoryWikiMutationInput } from "./apply.js";
import { compileMemoryWikiVault } from "./compile.js";
import {
  resolveAgentScopedConfig,
  WIKI_SEARCH_BACKENDS,
  WIKI_SEARCH_CORPORA,
  type ResolvedMemoryWikiConfig,
} from "./config.js";
import { listMemoryWikiImportInsights } from "./import-insights.js";
import { listMemoryWikiImportRuns } from "./import-runs.js";
import { ingestMemoryWikiSource } from "./ingest.js";
import { lintMemoryWikiVault } from "./lint.js";
import { listMemoryWikiPalace } from "./memory-palace.js";
import {
  probeObsidianCli,
  runObsidianCommand,
  runObsidianDaily,
  runObsidianOpen,
  runObsidianSearch,
} from "./obsidian.js";
import { getMemoryWikiPage, searchMemoryWiki, WIKI_SEARCH_MODES } from "./query.js";
import { syncMemoryWikiImportedSources } from "./source-sync.js";
import { buildMemoryWikiDoctorReport, resolveMemoryWikiStatus } from "./status.js";
import { initializeMemoryWikiVault } from "./vault.js";

const READ_SCOPE = "operator.read" as const;
const WRITE_SCOPE = "operator.write" as const;
type GatewayMethodContext = Parameters<
  Parameters<OpenClawPluginApi["registerGatewayMethod"]>[1]
>[0];
type GatewayRespond = GatewayMethodContext["respond"];

function readStringParam(params: Record<string, unknown>, key: string): string | undefined;
function readStringParam(
  params: Record<string, unknown>,
  key: string,
  options: { required: true },
): string;
function readStringParam(
  params: Record<string, unknown>,
  key: string,
  options?: { required?: boolean },
): string | undefined {
  const value = params[key];
  if (typeof value === "string" && value.trim()) {
    return value.trim();
  }
  if (options?.required) {
    throw new Error(`${key} is required.`);
  }
  return undefined;
}

function readNumberParam(params: Record<string, unknown>, key: string): number | undefined {
  const value = params[key];
  if (typeof value === "number" && Number.isFinite(value)) {
    return value;
  }
  if (typeof value === "string" && value.trim()) {
    const parsed = Number(value);
    if (Number.isFinite(parsed)) {
      return parsed;
    }
  }
  return undefined;
}

function readEnumParam<T extends string>(
  params: Record<string, unknown>,
  key: string,
  allowed: readonly T[],
): T | undefined {
  const value = readStringParam(params, key);
  if (!value) {
    return undefined;
  }
  if ((allowed as readonly string[]).includes(value)) {
    return value as T;
  }
  throw new Error(`${key} must be one of: ${allowed.join(", ")}.`);
}

function respondError(respond: GatewayRespond, error: unknown) {
  const message = formatErrorMessage(error);
  respond(false, undefined, { code: "internal_error", message });
}

function resolveAgentParam(requestParams: Record<string, unknown>): string | undefined {
  return readStringParam(requestParams, "agent");
}

async function syncImportedSourcesIfNeeded(
  config: ResolvedMemoryWikiConfig,
  appConfig?: OpenClawConfig,
) {
  await syncMemoryWikiImportedSources({ config, appConfig });
}

export function registerMemoryWikiGatewayMethods(params: {
  api: OpenClawPluginApi;
  config: ResolvedMemoryWikiConfig;
  appConfig?: OpenClawConfig;
}) {
  const { api, config, appConfig } = params;

  function agentScopedConfig(requestParams: Record<string, unknown>): ResolvedMemoryWikiConfig {
    const agent = resolveAgentParam(requestParams);
    return resolveAgentScopedConfig(config, agent);
  }

  api.registerGatewayMethod(
    "wiki.status",
    async ({ params: requestParams, respond }) => {
      try {
        const scopedConfig = agentScopedConfig(requestParams);
        await syncImportedSourcesIfNeeded(scopedConfig, appConfig);
        respond(
          true,
          await resolveMemoryWikiStatus(scopedConfig, {
            appConfig,
          }),
        );
      } catch (error) {
        respondError(respond, error);
      }
    },
    { scope: READ_SCOPE },
  );

  api.registerGatewayMethod(
    "wiki.importRuns",
    async ({ params: requestParams, respond }) => {
      try {
        const scopedConfig = agentScopedConfig(requestParams);
        const limit = readNumberParam(requestParams, "limit");
        respond(
          true,
          await listMemoryWikiImportRuns(scopedConfig, limit !== undefined ? { limit } : {}),
        );
      } catch (error) {
        respondError(respond, error);
      }
    },
    { scope: READ_SCOPE },
  );

  api.registerGatewayMethod(
    "wiki.importInsights",
    async ({ params: requestParams, respond }) => {
      try {
        const scopedConfig = agentScopedConfig(requestParams);
        await syncImportedSourcesIfNeeded(scopedConfig, appConfig);
        respond(true, await listMemoryWikiImportInsights(scopedConfig));
      } catch (error) {
        respondError(respond, error);
      }
    },
    { scope: READ_SCOPE },
  );

  api.registerGatewayMethod(
    "wiki.palace",
    async ({ params: requestParams, respond }) => {
      try {
        const scopedConfig = agentScopedConfig(requestParams);
        await syncImportedSourcesIfNeeded(scopedConfig, appConfig);
        respond(true, await listMemoryWikiPalace(scopedConfig));
      } catch (error) {
        respondError(respond, error);
      }
    },
    { scope: READ_SCOPE },
  );

  api.registerGatewayMethod(
    "wiki.init",
    async ({ params: requestParams, respond }) => {
      try {
        respond(true, await initializeMemoryWikiVault(agentScopedConfig(requestParams)));
      } catch (error) {
        respondError(respond, error);
      }
    },
    { scope: WRITE_SCOPE },
  );

  api.registerGatewayMethod(
    "wiki.doctor",
    async ({ params: requestParams, respond }) => {
      try {
        const scopedConfig = agentScopedConfig(requestParams);
        await syncImportedSourcesIfNeeded(scopedConfig, appConfig);
        const status = await resolveMemoryWikiStatus(scopedConfig, {
          appConfig,
        });
        respond(true, buildMemoryWikiDoctorReport(status));
      } catch (error) {
        respondError(respond, error);
      }
    },
    { scope: READ_SCOPE },
  );

  api.registerGatewayMethod(
    "wiki.compile",
    async ({ params: requestParams, respond }) => {
      try {
        const scopedConfig = agentScopedConfig(requestParams);
        await syncImportedSourcesIfNeeded(scopedConfig, appConfig);
        respond(true, await compileMemoryWikiVault(scopedConfig));
      } catch (error) {
        respondError(respond, error);
      }
    },
    { scope: WRITE_SCOPE },
  );

  api.registerGatewayMethod(
    "wiki.ingest",
    async ({ params: requestParams, respond }) => {
      try {
        const scopedConfig = agentScopedConfig(requestParams);
        const inputPath = readStringParam(requestParams, "inputPath", { required: true });
        const title = readStringParam(requestParams, "title");
        respond(
          true,
          await ingestMemoryWikiSource({
            config: scopedConfig,
            inputPath,
            ...(title ? { title } : {}),
          }),
        );
      } catch (error) {
        respondError(respond, error);
      }
    },
    { scope: WRITE_SCOPE },
  );

  api.registerGatewayMethod(
    "wiki.lint",
    async ({ params: requestParams, respond }) => {
      try {
        const scopedConfig = agentScopedConfig(requestParams);
        await syncImportedSourcesIfNeeded(scopedConfig, appConfig);
        respond(true, await lintMemoryWikiVault(scopedConfig));
      } catch (error) {
        respondError(respond, error);
      }
    },
    { scope: WRITE_SCOPE },
  );

  api.registerGatewayMethod(
    "wiki.bridge.import",
    async ({ params: requestParams, respond }) => {
      try {
        const scopedConfig = agentScopedConfig(requestParams);
        respond(
          true,
          await syncMemoryWikiImportedSources({
            config: { ...scopedConfig, vaultMode: "bridge" },
            appConfig,
          }),
        );
      } catch (error) {
        respondError(respond, error);
      }
    },
    { scope: WRITE_SCOPE },
  );

  api.registerGatewayMethod(
    "wiki.unsafeLocal.import",
    async ({ params: requestParams, respond }) => {
      try {
        const scopedConfig = agentScopedConfig(requestParams);
        respond(
          true,
          await syncMemoryWikiImportedSources({
            config: { ...scopedConfig, vaultMode: "unsafe-local" },
            appConfig,
          }),
        );
      } catch (error) {
        respondError(respond, error);
      }
    },
    { scope: WRITE_SCOPE },
  );

  api.registerGatewayMethod(
    "wiki.search",
    async ({ params: requestParams, respond }) => {
      try {
        const scopedConfig = agentScopedConfig(requestParams);
        await syncImportedSourcesIfNeeded(scopedConfig, appConfig);
        const query = readStringParam(requestParams, "query", { required: true });
        const maxResults = readNumberParam(requestParams, "maxResults");
        const searchBackend = readEnumParam(requestParams, "backend", WIKI_SEARCH_BACKENDS);
        const searchCorpus = readEnumParam(requestParams, "corpus", WIKI_SEARCH_CORPORA);
        const mode = readEnumParam(requestParams, "mode", WIKI_SEARCH_MODES);
        respond(
          true,
          await searchMemoryWiki({
            config: scopedConfig,
            appConfig,
            query,
            maxResults,
            searchBackend,
            searchCorpus,
            mode,
          }),
        );
      } catch (error) {
        respondError(respond, error);
      }
    },
    { scope: READ_SCOPE },
  );

  api.registerGatewayMethod(
    "wiki.apply",
    async ({ params: requestParams, respond }) => {
      try {
        const scopedConfig = agentScopedConfig(requestParams);
        await syncImportedSourcesIfNeeded(scopedConfig, appConfig);
        respond(
          true,
          await applyMemoryWikiMutation({
            config: scopedConfig,
            mutation: normalizeMemoryWikiMutationInput(requestParams),
          }),
        );
      } catch (error) {
        respondError(respond, error);
      }
    },
    { scope: WRITE_SCOPE },
  );

  api.registerGatewayMethod(
    "wiki.get",
    async ({ params: requestParams, respond }) => {
      try {
        const scopedConfig = agentScopedConfig(requestParams);
        await syncImportedSourcesIfNeeded(scopedConfig, appConfig);
        const lookup = readStringParam(requestParams, "lookup", { required: true });
        const fromLine = readNumberParam(requestParams, "fromLine");
        const lineCount = readNumberParam(requestParams, "lineCount");
        const searchBackend = readEnumParam(requestParams, "backend", WIKI_SEARCH_BACKENDS);
        const searchCorpus = readEnumParam(requestParams, "corpus", WIKI_SEARCH_CORPORA);
        respond(
          true,
          await getMemoryWikiPage({
            config: scopedConfig,
            appConfig,
            lookup,
            fromLine,
            lineCount,
            searchBackend,
            searchCorpus,
          }),
        );
      } catch (error) {
        respondError(respond, error);
      }
    },
    { scope: READ_SCOPE },
  );

  api.registerGatewayMethod(
    "wiki.obsidian.status",
    async ({ respond }) => {
      try {
        respond(true, await probeObsidianCli());
      } catch (error) {
        respondError(respond, error);
      }
    },
    { scope: READ_SCOPE },
  );

  api.registerGatewayMethod(
    "wiki.obsidian.search",
    async ({ params: requestParams, respond }) => {
      try {
        const query = readStringParam(requestParams, "query", { required: true });
        respond(true, await runObsidianSearch({ config: agentScopedConfig(requestParams), query }));
      } catch (error) {
        respondError(respond, error);
      }
    },
    { scope: READ_SCOPE },
  );

  api.registerGatewayMethod(
    "wiki.obsidian.open",
    async ({ params: requestParams, respond }) => {
      try {
        const vaultPath = readStringParam(requestParams, "path", { required: true });
        respond(
          true,
          await runObsidianOpen({ config: agentScopedConfig(requestParams), vaultPath }),
        );
      } catch (error) {
        respondError(respond, error);
      }
    },
    { scope: WRITE_SCOPE },
  );

  api.registerGatewayMethod(
    "wiki.obsidian.command",
    async ({ params: requestParams, respond }) => {
      try {
        const id = readStringParam(requestParams, "id", { required: true });
        respond(true, await runObsidianCommand({ config: agentScopedConfig(requestParams), id }));
      } catch (error) {
        respondError(respond, error);
      }
    },
    { scope: WRITE_SCOPE },
  );

  api.registerGatewayMethod(
    "wiki.obsidian.daily",
    async ({ params: requestParams, respond }) => {
      try {
        respond(true, await runObsidianDaily({ config: agentScopedConfig(requestParams) }));
      } catch (error) {
        respondError(respond, error);
      }
    },
    { scope: WRITE_SCOPE },
  );
}
