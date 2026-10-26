import { cp, rm } from 'node:fs/promises';

const destination = new URL('../LightroomMCP.lrplugin/', import.meta.url);
await rm(destination, { recursive: true, force: true });
await cp(new URL('../../plugin/LightroomMCP.lrplugin/', import.meta.url), destination,
  { recursive: true });
