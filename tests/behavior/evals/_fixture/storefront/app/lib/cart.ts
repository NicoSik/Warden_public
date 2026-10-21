import type {Cart, CartLine} from './types';

export function emptyCart(id: string): Cart {
  return {id, lines: []};
}

export function addLine(cart: Cart, line: CartLine): Cart {
  const existing = cart.lines.find((l) => l.productId === line.productId);
  if (!existing) return {...cart, lines: [...cart.lines, line]};
  return {
    ...cart,
    lines: cart.lines.map((l) =>
      l === existing ? {...l, quantity: l.quantity + line.quantity} : l,
    ),
  };
}

export function countItems(cart: Cart): number {
  return cart.lines.reduce((n, l) => n + l.quantity, 0);
}
