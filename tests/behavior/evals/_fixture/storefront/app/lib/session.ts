import type {Cart} from './types';

export type Session = {
  cartId?: string;
  locale: string;
};

const sessions = new Map<string, Session>();

export function getSession(id: string): Session {
  return sessions.get(id) ?? {locale: 'en-US'};
}

export function commitSession(id: string, session: Session): void {
  sessions.set(id, session);
}

export function attachCart(id: string, cart: Cart): Session {
  const session = {...getSession(id), cartId: cart.id};
  commitSession(id, session);
  return session;
}
