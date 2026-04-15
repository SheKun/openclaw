import fs from "node:fs/promises";
import { buildPluginConfigSchema, delegateCompactionToRuntime } from "openclaw/plugin-sdk/core";
import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";
import { z } from "openclaw/plugin-sdk/zod";

const configZodSchema = z.object({
  /** Explicit list of .md files to read and inject as system prompt additions. */
  files: z.array(z.string()).optional(),
});

type GuidanceConfig = z.infer<typeof configZodSchema>;

const configSchema = buildPluginConfigSchema(configZodSchema);

function toErrorMessage(err: unknown): string {
  if (err instanceof Error) {
    return err.message;
  }
  return String(err);
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

        for (const file of guidanceFiles) {
          try {
            const resolvedPath = api.resolvePath(file);
            const content = await fs.readFile(resolvedPath, "utf-8");
            systemPromptAddition += (systemPromptAddition ? "\n\n" : "") + content.trim();
          } catch (err: unknown) {
            api.logger.error(
              `guidance engine: failed to read file ${file}: ${toErrorMessage(err)}`,
            );
          }
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
