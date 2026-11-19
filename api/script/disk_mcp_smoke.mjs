// Smoke test for the Disk MCP endpoint with the official MCP TypeScript client
// (docs/plans/disk-build.md section 9c). It connects, lists tools, reads a
// page, writes a file and reads it back, then prints a JSON summary.
//
//   node api/script/disk_mcp_smoke.mjs <endpoint url> <agt_ token> <folder id> <page id>
//
// The SDK is the one ui/android/tools/android-mcp already installs; set
// MCP_SDK to another @modelcontextprotocol/sdk dist/esm directory to use a different copy.
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const sdk = process.env.MCP_SDK ||
  path.join(here, "../../ui/android/tools/android-mcp/node_modules/@modelcontextprotocol/sdk/dist/esm");
const { Client } = await import(pathToFileURL(path.join(sdk, "client/index.js")));
const { StreamableHTTPClientTransport } = await import(pathToFileURL(path.join(sdk, "client/streamableHttp.js")));

const [url, token, folderId, pageId] = process.argv.slice(2);
const transport = new StreamableHTTPClientTransport(new URL(url), {
  requestInit: { headers: { Authorization: `Bearer ${token}` } },
});
const client = new Client({ name: "disk-smoke", version: "1.0.0" });
await client.connect(transport);

const text = (r) => r.content.map((c) => c.text).join("\n");
const tools = (await client.listTools()).tools.map((t) => t.name);
const page = await client.callTool({ name: "disk_read_page", arguments: { id: pageId } });
const written = await client.callTool({
  name: "disk_write_file", arguments: { parent_id: folderId, name: "smoke.md", text: "written by the smoke test" },
});
const id = written.structuredContent.id;
const readBack = await client.callTool({ name: "disk_read_file", arguments: { id } });

console.log(JSON.stringify({
  protocol: transport.protocolVersion ?? null,
  server: client.getServerVersion(),
  tools,
  page: text(page),
  written: written.isError ? text(written) : id,
  readBack: text(readBack),
}));
await client.close();
