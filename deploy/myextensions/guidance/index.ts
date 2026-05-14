import path from "node:path";
import { buildPluginConfigSchema, delegateCompactionToRuntime } from "openclaw/plugin-sdk/core";
import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";
import { openFileWithinRoot } from "openclaw/plugin-sdk/security-runtime";
import { CONFIG_DIR } from "openclaw/plugin-sdk/setup-tools";
import { z } from "openclaw/plugin-sdk/zod";

const configZodSchema = z.object({
  /** Base directory used to resolve and validate guidance file paths. */
  rootDir: z.string().trim().min(1),
  /** Explicit list of .md files to read and inject as system prompt additions. */
  files: z.array(z.string()).optional(),
});

type GuidanceConfig = z.infer<typeof configZodSchema>;

const configSchema = buildPluginConfigSchema(configZodSchema);
const defaultGuidanceRootDir = path.resolve(CONFIG_DIR);

function toErrorMessage(err: unknown): string {
  if (err instanceof Error) {
    return err.message;
  }
  return String(err);
}

function toRootRelativePath(filePath: string, rootDir: string): string {
  const trimmed = filePath.trim();
  if (!trimmed) {
    throw new Error("guidance file path must not be empty");
  }

  const resolvedPath = path.isAbsolute(trimmed)
    ? path.resolve(trimmed)
    : path.resolve(rootDir, trimmed);
  const relativePath = path.relative(rootDir, resolvedPath);
  if (
    relativePath === ".." ||
    relativePath.startsWith(`..${path.sep}`) ||
    path.isAbsolute(relativePath)
  ) {
    throw new Error(`guidance file path must be inside configured rootDir: ${trimmed}`);
  }

  return relativePath;
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
        const config = api.pluginConfig as GuidanceConfig;
        const rootDir = path.resolve(config?.rootDir || defaultGuidanceRootDir);
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
            const relativePath = toRootRelativePath(file, rootDir);
            const opened = await openFileWithinRoot({
              rootDir,
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
