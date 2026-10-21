import {useLoaderData} from 'react-router';
import {CartLines} from '../components/CartLines';
import {getSession, attachCart} from '../lib/session';
import {addLine, emptyCart} from '../lib/cart';

export async function loader({request}: {request: Request}) {
  const sid = request.headers.get('x-session') ?? 'anon';
  const session = getSession(sid);
  return {cart: emptyCart(session.cartId ?? 'new')};
}

export async function action({request}: {request: Request}) {
  const sid = request.headers.get('x-session') ?? 'anon';
  const form = await request.formData();
  const cart = addLine(emptyCart('new'), {
    productId: String(form.get('productId')),
    quantity: 1,
  });
  attachCart(sid, cart);
  return {cart};
}

export default function CartPage() {
  const {cart} = useLoaderData<typeof loader>();
  return <CartLines cart={cart} />;
}
