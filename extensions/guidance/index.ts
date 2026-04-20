import path from "node:path";
import { CONFIG_DIR, openFileWithinRoot } from "openclaw/plugin-sdk/browser-support";
import { buildPluginConfigSchema, delegateCompactionToRuntime } from "openclaw/plugin-sdk/core";
import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";
import { z } from "openclaw/plugin-sdk/zod";

const configZodSchema = z.object({
  /** Explicit list of .md files to read and inject as system prompt additions. */
  files: z.array(z.string()).optional(),
});

type GuidanceConfig = z.infer<typeof configZodSchema>;

const configSchema = buildPluginConfigSchema(configZodSchema);
const openclawWorkspaceRoot = path.resolve(CONFIG_DIR);

function toErrorMessage(err: unknown): string {
  if (err instanceof Error) {
    return err.message;
  }
  return String(err);
}

function toWorkspaceRelativePath(filePath: string): string {
  const trimmed = filePath.trim();
  if (!trimmed) {
    throw new Error("guidance file path must not be empty");
  }
  if (path.isAbsolute(trimmed)) {
    return path.relative(openclawWorkspaceRoot, path.resolve(trimmed));
  }
  return trimmed;
}

export default definePluginEntry({
  id: "guidance",
  kind: "context-engine",
  name: "Global Guidance",
  description:
    "Global guidance context engine that injects prompt additions from configured files.",
  configSchema,
  register(api) {
    api.registerContextEngine("guidance", () => ({
      info: {
        id: "guidance",
        name: "Global Guidance",
        ownsCompaction: false,
      },

      async ingest() {
        return { ingested: true };
      },

      async assemble({ messages }) {
        const config = api.pluginConfig as GuidanceConfig | undefined;
        const guidanceFiles = config?.files ?? [];
        let systemPromptAddition = "";

        if (guidanceFiles.length === 0) {
          api.logger.debug?.(
            "guidance engine: no files configured; skipping system prompt addition",
          );
        }

        let loadedCount = 0;

        for (const file of guidanceFiles) {
          try {
            const relativePath = toWorkspaceRelativePath(file);
            const opened = await openFileWithinRoot({
              rootDir: openclawWorkspaceRoot,
              relativePath,
              rejectHardlinks: true,
            });
            let content = "";
            try {
              content = await opened.handle.readFile("utf-8");
            } finally {
              await opened.handle.close().catch(() => {});
            }
            const trimmed = content.trim();
            if (!trimmed) {
              api.logger.debug?.(
                `guidance engine: file ${file} resolved to ${opened.realPath} but content is empty`,
              );
              continue;
            }

            systemPromptAddition += (systemPromptAddition ? "\n\n" : "") + trimmed;
            loadedCount += 1;
            api.logger.debug?.(
              `guidance engine: loaded file ${file} (${trimmed.length} chars) from ${opened.realPath}`,
            );
          } catch (err: unknown) {
            api.logger.error(
              `guidance engine: failed to read file ${file}: ${toErrorMessage(err)}`,
            );
          }
        }

        if (guidanceFiles.length > 0 && loadedCount === 0) {
          api.logger.warn(
            "guidance engine: all configured files failed to load or were empty; no prompt addition generated",
          );
        } else if (loadedCount > 0) {
          api.logger.debug?.(
            `guidance engine: generated system prompt addition from ${loadedCount}/${guidanceFiles.length} files (${systemPromptAddition.length} chars)`,
          );
        }

        // Calculate a very rough token estimate (1 token per 4 chars)
        // for the combined messages and the guidance.
        const totalChars =
          messages.reduce((acc, m) => acc + JSON.stringify(m).length, 0) +
          systemPromptAddition.length;
        const estimatedTokens = Math.ceil(totalChars / 4);

        return {
          messages,
          estimatedTokens,
          systemPromptAddition,
        };
      },

      async compact(params) {
        return delegateCompactionToRuntime(params);
      },
    }));
  },
});
