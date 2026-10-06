import { execSync } from 'node:child_process';

/**
 * WSL2 default-route gateway IP = the Windows host, where Chrome's CDP port
 * listens. Copy of worker.mjs's getGatewayIp (that file is a monolith that
 * runs a worker on import, so it cannot be imported from a CLI).
 */
export function getGatewayIp() {
  const route = execSync("ip route show default | awk '{print $3}'").toString().trim();
  if (!route) throw new Error('could not determine WSL2 default-route gateway IP');
  return route;
}
