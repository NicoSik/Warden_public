export type Env = {
  PUBLIC_STORE_DOMAIN: string;
  SESSION_SECRET: string;
};

export function readEnv(source: Record<string, string | undefined>): Env {
  const domain = source.PUBLIC_STORE_DOMAIN;
  const secret = source.SESSION_SECRET;
  if (!domain || !secret) throw new Error('Missing environment variables');
  return {PUBLIC_STORE_DOMAIN: domain, SESSION_SECRET: secret};
}
