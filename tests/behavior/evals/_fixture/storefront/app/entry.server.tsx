import {readEnv} from './lib/env';

export function bootEnv() {
  return readEnv({
    PUBLIC_STORE_DOMAIN: process.env.PUBLIC_STORE_DOMAIN,
    SESSION_SECRET: process.env.SESSION_SECRET,
  });
}
