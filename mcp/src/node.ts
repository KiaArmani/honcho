import { WebStandardStreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/webStandardStreamableHttp.js";
import { parseConfig, createClient, type Env } from "./config.js";
import { createServer } from "./server.js";

declare const Bun: {
  env: Record<string, string | undefined>;
  serve(options: {
    port: number;
    hostname?: string;
    fetch(request: Request): Response | Promise<Response>;
  }): { url: URL };
};

const CORS_METHODS = "GET, POST, DELETE, OPTIONS";
const CORS_ALLOWED_HEADERS =
  "Content-Type, Authorization, X-Honcho-User-Name, X-Honcho-Workspace-ID, X-Honcho-Assistant-Name, Mcp-Session-Id, MCP-Protocol-Version";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": CORS_METHODS,
  "Access-Control-Allow-Headers": CORS_ALLOWED_HEADERS,
};

function withCors(response: Response): Response {
  const headers = new Headers(response.headers);
  for (const [key, value] of Object.entries(CORS_HEADERS)) {
    headers.set(key, value);
  }
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
}

function jsonResponse(data: unknown, status = 200): Response {
  return withCors(
    new Response(JSON.stringify(data), {
      status,
      headers: { "Content-Type": "application/json" },
    }),
  );
}

const honchoApiUrl = Bun.env.HONCHO_API_URL?.trim();
const port = Number(Bun.env.PORT || "8080");

if (!honchoApiUrl) {
  throw new Error(
    "HONCHO_API_URL is required for the self-hosted Honcho MCP server.",
  );
}

const env: Env = { HONCHO_API_URL: honchoApiUrl };

async function handleMcpRequest(request: Request): Promise<Response> {
  let server;
  let transport;

  try {
    const config = parseConfig(request, env);
    const honcho = createClient(config);
    server = createServer({ honcho, config });
    transport = new WebStandardStreamableHTTPServerTransport({
      sessionIdGenerator: undefined,
      enableJsonResponse: true,
    });

    await server.connect(transport);
    const response = await transport.handleRequest(request);
    await transport.close();
    await server.close();
    return withCors(response);
  } catch (e) {
    await transport?.close();
    await server?.close();
    const message = e instanceof Error ? e.message : "Internal server error";
    const status = message.startsWith("Missing ") ? 401 : 500;
    return jsonResponse({ error: message }, status);
  }
}

Bun.serve({
  hostname: "0.0.0.0",
  port,
  async fetch(request) {
    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: CORS_HEADERS });
    }

    const url = new URL(request.url);
    if (url.pathname === "/healthz") {
      return jsonResponse({
        ok: true,
        service: "honcho-mcp",
        target: honchoApiUrl,
      });
    }

    if (url.pathname !== "/" && url.pathname !== "/mcp") {
      return jsonResponse({ error: "Not found" }, 404);
    }

    return handleMcpRequest(request);
  },
});

console.log(`Honcho MCP server listening on 0.0.0.0:${port}`);
