import type {Cart} from '../lib/types';

export function CartLines({cart}: {cart: Cart}) {
  if (cart.lines.length === 0) return <p>Your cart is empty.</p>;
  return (
    <ul>
      {cart.lines.map((line) => (
        <li key={line.productId}>
          {line.productId} x {line.quantity}
        </li>
      ))}
    </ul>
  );
}
