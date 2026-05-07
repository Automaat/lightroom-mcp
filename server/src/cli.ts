export interface ParsedCli {
  command: "stdio" | "install-plugin" | "help" | "version";
}

const HELP = `lightroom-mcp — MCP bridge to Adobe Lightroom Classic

USAGE
  lightroom-mcp [stdio]            Run MCP over stdio (default)
  lightroom-mcp install-plugin     Install bundled .lrplugin into Lightroom Modules folder
  lightroom-mcp --help | --version

ENV
  LIGHTROOM_MCP_REQUEST_PORT   plugin request port  (default 58763)
  LIGHTROOM_MCP_RESPONSE_PORT  plugin response port (default 58764)
  LIGHTROOM_MCP_TOKEN_PATH     auth token file      (default ~/.config/lightroom-mcp/token)
`;

export function parseCli(argv: string[]): ParsedCli {
  const args = argv.slice(2);
  if (args.length === 0) return { command: "stdio" };

  const first = args[0];
  if (first === "--help" || first === "-h") return { command: "help" };
  if (first === "--version" || first === "-v") return { command: "version" };

  if (first === "stdio") return { command: "stdio" };
  if (first === "install-plugin") return { command: "install-plugin" };

  throw new Error(`Unknown command: ${first}\n\n${HELP}`);
}

export function helpText(): string {
  return HELP;
}
